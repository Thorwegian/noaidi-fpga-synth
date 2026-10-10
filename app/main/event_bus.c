// event_bus.c — tiny publish/subscribe fan-out for inter-task events
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// See event_bus.h for the design rationale.

#include "event_bus.h"

static QueueHandle_t s_subs[EVENT_BUS_MAX_SUBSCRIBERS];

void event_bus_init(void)
{
    for (int i = 0; i < EVENT_BUS_MAX_SUBSCRIBERS; i++) {
        s_subs[i] = NULL;
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
        xQueueSend(q, evt, 0);   // full queue: the event is dropped
    }
}

