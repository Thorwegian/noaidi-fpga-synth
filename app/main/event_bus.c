// event_bus.c — tiny publish/subscribe fan-out for inter-task events
//
// See event_bus.h for the design rationale.

#include "event_bus.h"

static QueueHandle_t s_subs[EVENT_BUS_MAX_SUBSCRIBERS];
static uint32_t s_dropped[EVENT_BUS_MAX_SUBSCRIBERS];

void event_bus_init(void)
{
    for (int i = 0; i < EVENT_BUS_MAX_SUBSCRIBERS; i++) {
        s_subs[i] = NULL;
        s_dropped[i] = 0;
    }
}

int event_bus_subscribe(QueueHandle_t queue)
{
    for (int i = 0; i < EVENT_BUS_MAX_SUBSCRIBERS; i++) {
        if (s_subs[i] == NULL) {
            s_subs[i] = queue;
            return i;
        }
    }
    return -1;
}

void event_bus_publish(const evt_t *evt)
{
    for (int i = 0; i < EVENT_BUS_MAX_SUBSCRIBERS; i++) {
        QueueHandle_t q = s_subs[i];
        if (q == NULL) {
            continue;
        }
        if (xQueueSend(q, evt, 0) != pdTRUE) {
            s_dropped[i]++;
        }
    }
}

uint32_t event_bus_dropped(int sub_id)
{
    if (sub_id < 0 || sub_id >= EVENT_BUS_MAX_SUBSCRIBERS) {
        return 0;
    }
    return s_dropped[sub_id];
}

void event_bus_reset_dropped(int sub_id)
{
    if (sub_id >= 0 && sub_id < EVENT_BUS_MAX_SUBSCRIBERS) {
        s_dropped[sub_id] = 0;
    }
}
