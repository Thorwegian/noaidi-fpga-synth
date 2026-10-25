// event_bus.h — tiny publish/subscribe fan-out for inter-task events
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Consumers subscribe one FreeRTOS queue (holding evt_t items);
// publishers fan each event out to every subscriber with a
// non-blocking send. Events that cannot be delivered (subscriber
// queue full) are dropped, so no producer ever blocks on a slow
// consumer.
//
// Consumers then run a single event loop on their own queue — all
// their state stays inside that loop, no locks needed.
//
// The subscriber table is static configuration done at boot (before
// tasks start publishing), so the table itself needs no locking.

#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"

#include "midi_parser.h"

#ifdef __cplusplus
extern "C" {
#endif

#define EVENT_BUS_MAX_SUBSCRIBERS 4

typedef enum {
    EVT_MIDI = 1,
    EVT_PRESET, // a preset request to voice_alloc (voice_alloc.h)
    EVT_SYNC, // the console asks voice_alloc to send the preset to the surfaces (#279)
} evt_kind_t;

// Where a MIDI event came from. The outputs send a state change to every
// other source's surface (parameter feedback, #279), never back to its own.
typedef enum {
    MIDI_SOURCE_INTERNAL = 0, // the firmware itself: the console, a rule
    MIDI_SOURCE_DIN,          // UART1, the DIN jack
    MIDI_SOURCE_PANEL,        // UART0, the dev host's panel port
    MIDI_SOURCE_BLE,          // MIDI over Bluetooth LE
} midi_source_t;

// A preset request: replace the active preset, or copy it out. Sent
// straight to voice_alloc's queue, so it stays in order with MIDI; the
// sender waits on done.
typedef struct {
    bool set; // true: *preset becomes the active preset;
              // false: the active preset is copied to *preset
    struct preset_s *preset;
    SemaphoreHandle_t done;
} preset_request_t;

// Tagged union: extend with new kinds and members as the system grows.
typedef struct {
    evt_kind_t kind;
    uint8_t source; // midi_source_t, with EVT_MIDI
    union {
        midi_message_t midi;
        preset_request_t preset;
    };
} evt_t;

// Call once at boot, before any subscribe/publish.
void event_bus_init(void);

// Register a consumer queue. Returns the subscriber id (>= 0) or -1
// if no subscriber slot is free.
int event_bus_subscribe(QueueHandle_t queue);

// Fan the event out to all subscribers. Non-blocking: if a subscriber
// queue is full the event is dropped for that subscriber.
void event_bus_publish(const evt_t *evt);

#ifdef __cplusplus
}
#endif
