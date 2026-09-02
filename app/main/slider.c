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

// 500 Hz polls through a ROLLING 8-sample average: measured on the
// board, single-sample ADC noise swings past half a CC step (637
// spurious ±1 events in 20 s of idle), so filtering is required —
// but a rolling window updated every poll keeps the event rate at
// 500 Hz with only 8 ms of group delay, unlike the original
// block-average-then-sleep shape that made a 50 Hz knob.
// Pacing is an esp_timer notifying the task — same pattern and same
// reason as engine_link's 1 kHz tick (see engine_link.c: short
// vTaskDelay rounds to zero ticks and busy-spins).
#define POLL_US        2000   // slider poll period
#define WIN_LEN        8      // rolling-average window (power of 2)
// CC-level backlash hysteresis (Thor's design: "a change of 1 isn't
// enough — a window of 2 that is allowed to move in steps of 1").
// The sent value owns a ±1 window; a candidate inside it changes
// nothing, a candidate beyond it drags the sent value to the window
// edge. Parked ±1 flicker is structurally silent; slow travel steps
// by 1. Rails adopt exactly so 0 and 127 stay reachable.
// Two-point settled calibration (Thor's design: the continuous
// min/max "seen" capture grabbed transients — pressure against an
// end stop reads ~50 counts beyond where that end rests). Each end
// is captured deliberately: park the fader, press the key, the
// firmware averages a full second (500 raw samples — noise settles
// to a fraction of a count), and that RESTING value becomes the
// end. Ends persist independently, so either can be redone alone.
#define CAPTURE_POLLS  500    // 1 s of settling average per end
#define END_MARGIN_DIV 64     // span/64 pulled inward from each
                              // settled end so the rails stay
                              // reachable across drift (~1-2 CC of
                              // plateau at each end of travel)
#define MIN_CAL_SPAN   500    // raw counts; smaller span = the two
                              // ends clearly aren't a full travel

// Divider math defaults (680R / 10k pot / 3k6 at 3.3V, 12-bit ADC at
// max attenuation): wiper ~0.16 V .. ~2.47 V -> roughly these counts.
// Calibration replaces them; these only make an uncalibrated unit
// behave sanely.
#define DEFAULT_RAW_MIN  260
#define DEFAULT_RAW_MAX  4000

#define NVS_NAMESPACE   "panel"
#define NVS_KEY_END_MIN "end_min"     // settled resting end values
#define NVS_KEY_END_MAX "end_max"
#define NVS_KEY_MIN     "sl_min"      // legacy working-range keys,
#define NVS_KEY_MAX     "sl_max"      // read as fallback only

static adc_oneshot_unit_handle_t s_adc;
static uint16_t s_raw_min = DEFAULT_RAW_MIN;   // working range
static uint16_t s_raw_max = DEFAULT_RAW_MAX;
static uint16_t s_end_min = DEFAULT_RAW_MIN;   // settled end values
static uint16_t s_end_max = DEFAULT_RAW_MAX;

static volatile uint8_t s_capture_end = 0;     // 0 idle, 1 min, 2 max
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

// Working range = settled ends pulled inward by span/64.
static void apply_ends(void)
{
    if (s_end_max <= s_end_min + MIN_CAL_SPAN) {
        ESP_LOGW(TAG, "ends %u..%u too close, keeping range %u..%u",
                 s_end_min, s_end_max, s_raw_min, s_raw_max);
        return;
    }
    uint16_t margin = (uint16_t)((s_end_max - s_end_min) / END_MARGIN_DIV);
    s_raw_min = s_end_min + margin;
    s_raw_max = s_end_max - margin;
    ESP_LOGI(TAG, "range: ends %u..%u -> working %u..%u",
             s_end_min, s_end_max, s_raw_min, s_raw_max);
}

static void load_calibration(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &h) != ESP_OK) {
        ESP_LOGI(TAG, "no stored calibration, using divider defaults");
        return;
    }
    uint16_t mn, mx;
    if (nvs_get_u16(h, NVS_KEY_END_MIN, &mn) == ESP_OK &&
        nvs_get_u16(h, NVS_KEY_END_MAX, &mx) == ESP_OK) {
        s_end_min = mn;
        s_end_max = mx;
        apply_ends();
    } else if (nvs_get_u16(h, NVS_KEY_MIN, &mn) == ESP_OK &&
               nvs_get_u16(h, NVS_KEY_MAX, &mx) == ESP_OK &&
               mx > mn + MIN_CAL_SPAN) {
        // legacy working range: use as provisional ends until the
        // two-point capture replaces them
        s_end_min = mn;
        s_end_max = mx;
        s_raw_min = mn;
        s_raw_max = mx;
        ESP_LOGI(TAG, "legacy calibration loaded: %u..%u "
                      "(recapture ends with '1'/'2')", mn, mx);
    }
    nvs_close(h);
}

static void save_ends(void)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "NVS open failed: %s", esp_err_to_name(err));
        return;
    }
    nvs_set_u16(h, NVS_KEY_END_MIN, s_end_min);
    nvs_set_u16(h, NVS_KEY_END_MAX, s_end_max);
    err = nvs_commit(h);
    nvs_close(h);
    ESP_LOGI(TAG, "ends saved: %u..%u (%s)", s_end_min, s_end_max,
             err == ESP_OK ? "committed" : esp_err_to_name(err));
}

static void slider_task(void *arg)
{
    uint8_t last_cc  = 0xFF;       // force one send at boot
    int     win[WIN_LEN] = {0};
    int     win_idx = 0, win_sum = 0, win_fill = 0;
    int32_t cap_sum = 0;
    int     cap_n   = 0;

    while (1) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        int sample = read_raw();
        if (sample < 0)
            continue;

        if (s_capture_end) {
            // settle one end: average raw samples for a full second
            cap_sum += sample;
            if (++cap_n >= CAPTURE_POLLS) {
                int mean = cap_sum / cap_n;
                cap_sum = 0; cap_n = 0;
                if (s_capture_end == 1) s_end_min = (uint16_t)mean;
                else                    s_end_max = (uint16_t)mean;
                ESP_LOGI(TAG, "%s end settled: raw %d",
                         s_capture_end == 1 ? "MIN" : "MAX", mean);
                s_capture_end = 0;
                apply_ends();
                save_ends();
            }
            continue;
        }
        cap_sum = 0; cap_n = 0;

        // rolling average: updated every poll, ~8 ms group delay
        win_sum += sample - win[win_idx];
        win[win_idx] = sample;
        win_idx = (win_idx + 1) % WIN_LEN;
        if (win_fill < WIN_LEN) {          // warm-up: fill first
            win_fill++;
            continue;
        }
        int raw = win_sum / WIN_LEN;

        uint8_t cc = raw_to_cc(raw);
        uint8_t send;
        if (last_cc == 0xFF)
            send = cc;                          // first value at boot
        else if (cc == 127 && last_cc < 127)
            send = 127;                         // rails adopt exactly
        else if (cc == 0 && last_cc > 0)
            send = 0;
        else if ((int)cc - (int)last_cc >= 2)
            send = cc - 1;                      // drag to window edge
        else if ((int)last_cc - (int)cc >= 2)
            send = cc + 1;
        else
            continue;                           // inside the window

        last_cc = send;
        publish_cc(send);
    }
}

static void console_task(void *arg)
{
    uint8_t ch;
    while (1) {
        int n = usb_serial_jtag_read_bytes(&ch, 1, portMAX_DELAY);
        if (n <= 0)
            continue;
        if (ch == '1' && !s_capture_end) {
            ESP_LOGI(TAG, "park the fader at the MIN end - settling 1 s");
            s_capture_end = 1;
        } else if (ch == '2' && !s_capture_end) {
            ESP_LOGI(TAG, "park the fader at the MAX end - settling 1 s");
            s_capture_end = 2;
        } else if (ch == 'r' || ch == 'R') {
            int raw = read_raw();
            ESP_LOGI(TAG, "raw=%d cc=%u ends=%u..%u working=%u..%u",
                     raw, raw_to_cc(raw), s_end_min, s_end_max,
                     s_raw_min, s_raw_max);
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
    ESP_LOGI(TAG, "keys: 1=capture MIN end  2=capture MAX end  r=read");
    const esp_timer_create_args_t targs = {
        .callback = poll_timer_cb,
        .name     = "slider_poll",
    };
    esp_timer_handle_t timer;
    ESP_ERROR_CHECK(esp_timer_create(&targs, &timer));
    ESP_ERROR_CHECK(esp_timer_start_periodic(timer, POLL_US));
    xTaskCreate(console_task, "slider_con", 3072, NULL, 3, NULL);
    ESP_LOGI(TAG, "slider on GPIO1/ADC1_CH1 -> CC71");
}
