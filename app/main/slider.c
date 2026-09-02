// slider.c — panel slider on GPIO1/A1 → internal resonance CC
// (see slider.h for the wiring and console keys)

#include "slider.h"

#include <stdint.h>
#include <stdbool.h>

#include "esp_log.h"
#include "esp_timer.h"
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

// 500 Hz single-sample polls: one CC step spans ~30 raw counts, so
// ADC noise sits well under a step and averaging adds nothing but
// lag at 7-bit resolution (Thor). Movement hysteresis replaces the
// old debounce: instant while moving, silent while parked.
// Pacing is an esp_timer notifying the task — same pattern and same
// reason as engine_link's 1 kHz tick: the FreeRTOS tick is 100 Hz,
// so a 2 ms vTaskDelay rounds to ZERO ticks and busy-spins (caught
// by the task watchdog on the first hardware run).
#define POLL_US        2000   // slider poll period
#define HYST_COUNTS    8      // raw movement needed to re-evaluate
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
static TaskHandle_t s_poll_task;

static void poll_timer_cb(void *arg)
{
    xTaskNotifyGive(s_poll_task);   // runs in the esp_timer task
}

static int read_raw(void)
{
    int v = 0;
    if (adc_oneshot_read(s_adc, SLIDER_ADC_CHANNEL, &v) != ESP_OK)
        return -1;
    return v;
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
    uint8_t last_cc  = 0xFF;       // force one send at boot
    int     last_raw = -10000;     // ditto
    int     cal_print = 0;

    while (1) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        int raw = read_raw();
        if (raw < 0)
            continue;

        if (s_calibrating) {
            if (raw < s_cal_min) s_cal_min = (uint16_t)raw;
            if (raw > s_cal_max) s_cal_max = (uint16_t)raw;
            if (++cal_print >= 100) {          // every ~200 ms
                cal_print = 0;
                ESP_LOGI(TAG, "CAL raw=%d seen %u..%u",
                         raw, s_cal_min, s_cal_max);
            }
            continue;
        }

        // Re-evaluate only after real movement (~1/4 CC step), so a
        // parked slider on a step boundary can't chatter; a moving
        // slider updates at the poll rate, one poll of latency.
        if (raw - last_raw < HYST_COUNTS && last_raw - raw < HYST_COUNTS)
            continue;
        last_raw = raw;

        uint8_t cc = raw_to_cc(raw);
        if (cc != last_cc) {
            last_cc = cc;
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
            int raw = read_raw();
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

    xTaskCreate(slider_task, "slider", 3072, NULL, 4, &s_poll_task);
    const esp_timer_create_args_t targs = {
        .callback = poll_timer_cb,
        .name     = "slider_poll",
    };
    esp_timer_handle_t timer;
    ESP_ERROR_CHECK(esp_timer_create(&targs, &timer));
    ESP_ERROR_CHECK(esp_timer_start_periodic(timer, POLL_US));
    xTaskCreate(console_task, "slider_con", 3072, NULL, 3, NULL);
    ESP_LOGI(TAG, "slider on GPIO1/ADC1_CH1 -> CC71; keys: c=cal r=read");
}
