// slider.c — panel slider on GPIO1/A1 → internal resonance CC
// (see slider.h for the wiring and console keys)

#include "slider.h"

#include <stdint.h>
#include <stdbool.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_adc/adc_oneshot.h"
#include "driver/usb_serial_jtag.h"
#include "nvs_flash.h"
#include "nvs.h"

#include "event_bus.h"

#define TAG "slider"

// GPIO1 on the ESP32-C3 is ADC1 channel 1.
#define SLIDER_ADC_UNIT     ADC_UNIT_1
#define SLIDER_ADC_CHANNEL  ADC_CHANNEL_1

#define POLL_MS        20     // slider poll period
#define AVG_SAMPLES    8      // per poll, averaged against ADC noise
#define STABLE_POLLS   2      // a new CC value must hold this many
                              // polls before it is sent (debounce)
#define MIN_CAL_SPAN   500    // raw counts; smaller = calibration
                              // clearly didn't see full travel

// Divider math defaults (680R / 10k pot / 3k6 at 3.3V, 12-bit ADC at
// max attenuation): wiper ~0.16 V .. ~2.47 V -> roughly these counts.
// Calibration replaces them; these only make an uncalibrated unit
// behave sanely.
#define DEFAULT_RAW_MIN  260
#define DEFAULT_RAW_MAX  4000

#define NVS_NAMESPACE  "panel"
#define NVS_KEY_MIN    "sl_min"
#define NVS_KEY_MAX    "sl_max"

static adc_oneshot_unit_handle_t s_adc;
static uint16_t s_raw_min = DEFAULT_RAW_MIN;
static uint16_t s_raw_max = DEFAULT_RAW_MAX;

static volatile bool s_calibrating = false;
static uint16_t s_cal_min, s_cal_max;

static int read_raw_avg(void)
{
    int sum = 0, v = 0;
    for (int i = 0; i < AVG_SAMPLES; i++) {
        if (adc_oneshot_read(s_adc, SLIDER_ADC_CHANNEL, &v) != ESP_OK)
            return -1;
        sum += v;
    }
    return sum / AVG_SAMPLES;
}

static uint8_t raw_to_cc(int raw)
{
    if (raw <= s_raw_min) return 0;
    if (raw >= s_raw_max) return 127;
    return (uint8_t)(((raw - s_raw_min) * 127) / (s_raw_max - s_raw_min));
}

// The slider IS a MIDI controller as far as the synth model knows:
// it publishes CC 71 on the event bus, and voice_alloc's handler
// (the temporary resonance assignment) takes it from there.
static void publish_cc(uint8_t value)
{
    evt_t evt = {
        .kind = EVT_MIDI,
        .midi = {.status = 0xB0, .len = 2, .data = {71, value}},
    };
    event_bus_publish(&evt);
}

static void load_calibration(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &h) != ESP_OK) {
        ESP_LOGI(TAG, "no stored calibration, using divider defaults");
        return;
    }
    uint16_t mn, mx;
    if (nvs_get_u16(h, NVS_KEY_MIN, &mn) == ESP_OK &&
        nvs_get_u16(h, NVS_KEY_MAX, &mx) == ESP_OK &&
        mx > mn + MIN_CAL_SPAN) {
        s_raw_min = mn;
        s_raw_max = mx;
        ESP_LOGI(TAG, "calibration loaded: raw %u..%u", mn, mx);
    }
    nvs_close(h);
}

static void save_calibration(uint16_t mn, uint16_t mx)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "NVS open failed: %s", esp_err_to_name(err));
        return;
    }
    nvs_set_u16(h, NVS_KEY_MIN, mn);
    nvs_set_u16(h, NVS_KEY_MAX, mx);
    err = nvs_commit(h);
    nvs_close(h);
    ESP_LOGI(TAG, "calibration saved: raw %u..%u (%s)", mn, mx,
             err == ESP_OK ? "committed" : esp_err_to_name(err));
}

static void slider_task(void *arg)
{
    uint8_t last_cc = 0xFF;        // force one send at boot
    uint8_t pending_cc = 0xFF;
    int     pending_polls = 0;
    int     cal_print = 0;

    while (1) {
        vTaskDelay(pdMS_TO_TICKS(POLL_MS));
        int raw = read_raw_avg();
        if (raw < 0)
            continue;

        if (s_calibrating) {
            if (raw < s_cal_min) s_cal_min = (uint16_t)raw;
            if (raw > s_cal_max) s_cal_max = (uint16_t)raw;
            if (++cal_print >= 10) {           // every ~200 ms
                cal_print = 0;
                ESP_LOGI(TAG, "CAL raw=%d seen %u..%u",
                         raw, s_cal_min, s_cal_max);
            }
            continue;
        }

        uint8_t cc = raw_to_cc(raw);
        if (cc == last_cc) {
            pending_cc = 0xFF;
            continue;
        }
        if (cc != pending_cc) {
            pending_cc = cc;
            pending_polls = 1;
            continue;
        }
        if (++pending_polls >= STABLE_POLLS) {
            last_cc = cc;
            pending_cc = 0xFF;
            publish_cc(cc);
        }
    }
}

static void console_task(void *arg)
{
    uint8_t ch;
    while (1) {
        int n = usb_serial_jtag_read_bytes(&ch, 1, portMAX_DELAY);
        if (n <= 0)
            continue;
        if (ch == 'c' || ch == 'C') {
            if (!s_calibrating) {
                s_cal_min = UINT16_MAX;
                s_cal_max = 0;
                s_calibrating = true;
                ESP_LOGI(TAG, "CAL START: run the slider end to end, "
                              "then press 'c' to save");
            } else {
                s_calibrating = false;
                if (s_cal_max > s_cal_min &&
                    (uint16_t)(s_cal_max - s_cal_min) > MIN_CAL_SPAN) {
                    s_raw_min = s_cal_min;
                    s_raw_max = s_cal_max;
                    save_calibration(s_cal_min, s_cal_max);
                } else {
                    ESP_LOGW(TAG, "CAL ABORT: span %u..%u too small, "
                                  "keeping %u..%u",
                             s_cal_min, s_cal_max, s_raw_min, s_raw_max);
                }
            }
        } else if (ch == 'r' || ch == 'R') {
            int raw = read_raw_avg();
            ESP_LOGI(TAG, "raw=%d cc=%u cal=%u..%u",
                     raw, raw_to_cc(raw), s_raw_min, s_raw_max);
        }
    }
}

void slider_init(void)
{
    // NVS backs the calibration (no EEPROM on this chip; NVS is the
    // flash-based equivalent). A full/version-mismatched partition
    // gets erased and reinitialized — it only ever holds settings.
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES ||
        err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
    load_calibration();

    adc_oneshot_unit_init_cfg_t unit_cfg = {.unit_id = SLIDER_ADC_UNIT};
    ESP_ERROR_CHECK(adc_oneshot_new_unit(&unit_cfg, &s_adc));
    adc_oneshot_chan_cfg_t chan_cfg = {
        .atten    = ADC_ATTEN_DB_12,          // max range (~2.5 V usable)
        .bitwidth = ADC_BITWIDTH_DEFAULT,     // 12-bit on the C3
    };
    ESP_ERROR_CHECK(adc_oneshot_config_channel(s_adc, SLIDER_ADC_CHANNEL,
                                               &chan_cfg));

    // Console keys arrive over the USB-Serial-JTAG the monitor is
    // already attached to; the driver gives us blocking reads.
    // The driver insists on buffers STRICTLY larger than 64 bytes
    // (install returns ESP_ERR_INVALID_ARG otherwise — found the
    // hard way, panic at boot).
    usb_serial_jtag_driver_config_t usj_cfg = {
        .rx_buffer_size = 256,
        .tx_buffer_size = 256,
    };
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&usj_cfg));

    xTaskCreate(slider_task, "slider", 3072, NULL, 4, NULL);
    xTaskCreate(console_task, "slider_con", 3072, NULL, 3, NULL);
    ESP_LOGI(TAG, "slider on GPIO1/ADC1_CH1 -> CC71; keys: c=cal r=read");
}
