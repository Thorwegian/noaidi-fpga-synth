// stress_test.c — synthetic MIDI flood to reproduce load crashes (#70).
//
// Publishes the exact abuse Thor hits by hand -- continuous CC sweeps
// (voice mode 26, volume 7, mix 24) interleaved with note on/off so the
// voice pool stays busy with release tails -- straight onto the event
// bus, the same path midi_in/ble_midi feed. Deterministic repro with no
// external controller. Enabled by CONFIG_NOAIDI_STRESS_TEST.

#include "stress_test.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_timer.h"

#include "event_bus.h"

#define TAG "stress"

#define STRESS_SECONDS   60
#define STRESS_BURST     8      // messages published back-to-back per yield

static void pub(uint8_t status, uint8_t d0, uint8_t d1)
{
    evt_t e = { .kind = EVT_MIDI };
    e.midi.status  = status;
    e.midi.len     = 2;
    e.midi.data[0] = d0;
    e.midi.data[1] = d1;
    event_bus_publish(&e);
}

static void stress_task(void *arg)
{
    (void)arg;
    vTaskDelay(pdMS_TO_TICKS(3000));   // let boot + BLE settle
    ESP_LOGW(TAG, "STRESS FLOOD START (%d s): CC 26/7/24 sweeps + note churn",
             STRESS_SECONDS);

    static const uint8_t notes[] = {52, 55, 57, 60, 64, 48};
    uint8_t  cc = 0;
    unsigned ni = 0;
    int64_t  t0 = esp_timer_get_time();

    while (esp_timer_get_time() - t0 < (int64_t)STRESS_SECONDS * 1000000LL) {
        for (int b = 0; b < STRESS_BURST; b++) {
            cc = (uint8_t)((cc + 3) & 0x7F);
            pub(0xB0, 26, cc);                       // voice mode (the trigger)
            pub(0xB0, 7,  (uint8_t)((cc * 2) & 0x7F)); // master volume
            pub(0xB0, 24, cc);                       // osc mix
            uint8_t n = notes[ni % (sizeof notes)];
            if (ni & 1u) pub(0x80, n, 0);            // note off
            else         pub(0x90, n, 40);           // note on
            ni++;
        }
        vTaskDelay(1);                    // yield one tick between bursts
    }

    pub(0xB0, 123, 0);                    // all notes off
    ESP_LOGW(TAG, "STRESS FLOOD SURVIVED %d s (%u note events)",
             STRESS_SECONDS, ni);
    vTaskDelete(NULL);
}

void stress_test_start(void)
{
    xTaskCreate(stress_task, "stress", 3072, NULL, 4, NULL);
}
