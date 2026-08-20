// event_bus.h — tiny publish/subscribe fan-out for inter-task events
//
// Consumers subscribe one FreeRTOS queue (holding evt_t items);
// publishers fan each event out to every subscriber with a
// non-blocking send. Events that cannot be delivered (subscriber
// queue full) are dropped and counted per subscriber, so no producer
// ever blocks on a slow consumer.
//
// Consumers then run a single event loop on their own queue — all
// their state stays inside that loop, no locks needed.
//
// The subscriber table is static configuration done at boot (before
// tasks start publishing), so the table itself needs no locking.
// Drop counters are 32-bit and only observed asynchronously, which is
// benign.

#pragma once

#include <stdint.h>

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

#include "midi_parser.h"

#ifdef __cplusplus
extern "C" {
#endif

#define EVENT_BUS_MAX_SUBSCRIBERS 4

typedef enum {
    EVT_MIDI = 1,
} evt_kind_t;

// Tagged union: extend with new kinds and members as the system grows.
typedef struct {
    evt_kind_t kind;
    union {
        midi_message_t midi;
    };
} evt_t;

// Call once at boot, before any subscribe/publish.
void event_bus_init(void);

// Register a consumer queue. Returns the subscriber id (>= 0) or -1
// if no subscriber slot is free.
int event_bus_subscribe(QueueHandle_t queue);

// Fan the event out to all subscribers. Non-blocking: if a subscriber
// queue is full the event is dropped (and counted) for that subscriber.
void event_bus_publish(const evt_t *evt);

// Number of events dropped for a subscriber since the last reset.
uint32_t event_bus_dropped(int sub_id);

void event_bus_reset_dropped(int sub_id);

#ifdef __cplusplus
}
#endif
