// midi_log.c — console monitor task for MIDI events
//
// Subscribes to the event bus with its own queue and runs a single
// event loop that decodes MIDI messages and prints them. This is the
// only place MIDI traffic is printed: the RX task never blocks on the
// console, and if the console cannot keep up, events are dropped here
// (and counted) instead of stalling the MIDI input.

#include "midi_log.h"

#include <inttypes.h>
#include <stdio.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include "event_bus.h"

#define MIDI_LOG_QUEUE_LEN  64
#define MIDI_LOG_TASK_STACK 2048
#define MIDI_LOG_TASK_PRIO  4

static QueueHandle_t s_queue;
static int s_sub_id = -1;

static void log_midi_event(const midi_message_t *m)
{
    uint8_t type = m->status & 0xF0;
    uint8_t ch   = (m->status & 0x0F) + 1;

    switch (type) {
    case 0x80:
        printf("note_off  ch=%2d note=%3d vel=%3d\n", ch, m->data[0], m->data[1]);
        break;
    case 0x90:
        printf("note_on   ch=%2d note=%3d vel=%3d\n", ch, m->data[0], m->data[1]);
        break;
    case 0xA0:
        printf("poly_at   ch=%2d note=%3d val=%3d\n", ch, m->data[0], m->data[1]);
        break;
    case 0xB0:
        printf("cc        ch=%2d num=%3d val=%3d\n", ch, m->data[0], m->data[1]);
        break;
    case 0xC0:
        printf("program   ch=%2d num=%3d\n", ch, m->data[0]);
        break;
    case 0xD0:
        printf("ch_at     ch=%2d val=%3d\n", ch, m->data[0]);
        break;
    case 0xE0:
        printf("pitch     ch=%2d val=%5d\n", ch, (m->data[1] << 7) | m->data[0]);
        break;
    default:
        printf("unknown   status=0x%02X\n", m->status);
        break;
    }
}

static void midi_log_task(void *arg)
{
    evt_t evt;
    bool drop_logged = false;

    while (1) {
        if (xQueueReceive(s_queue, &evt, portMAX_DELAY) != pdTRUE) {
            continue;
        }

        // Report drops once per burst, not once per event.
        uint32_t dropped = event_bus_dropped(s_sub_id);
        if (dropped > 0) {
            if (!drop_logged) {
                ESP_LOGW("midi_log", "console too slow, dropped %" PRIu32
                         " events since last report", dropped);
                drop_logged = true;
            }
            event_bus_reset_dropped(s_sub_id);
        } else {
            drop_logged = false;
        }

        switch (evt.kind) {
        case EVT_MIDI:
            log_midi_event(&evt.midi);
            break;
        default:
            ESP_LOGW("midi_log", "unknown event kind %d", evt.kind);
            break;
        }
    }
}

void midi_log_init(void)
{
    s_queue = xQueueCreate(MIDI_LOG_QUEUE_LEN, sizeof(evt_t));
    if (s_queue == NULL) {
        ESP_LOGE("midi_log", "Failed to create event queue");
        return;
    }

    s_sub_id = event_bus_subscribe(s_queue);
    if (s_sub_id < 0) {
        ESP_LOGE("midi_log", "No free subscriber slot on event bus");
        return;
    }

    BaseType_t ok = xTaskCreate(midi_log_task, "midi_log", MIDI_LOG_TASK_STACK,
                                NULL, MIDI_LOG_TASK_PRIO, NULL);
    if (ok != pdPASS) {
        ESP_LOGE("midi_log", "Failed to create task");
        return;
    }

    ESP_LOGI("midi_log", "Subscribed to event bus (id %d)", s_sub_id);
}
