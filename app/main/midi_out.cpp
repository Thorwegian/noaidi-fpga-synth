// midi_out.cpp — the synth's MIDI outputs (see midi_out.h)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One queue, one task at priority 3: below the MIDI inputs and the voices,
// so feedback never delays a note, above the console. The task drains the
// queue into MIDI 1.0 over BLE packets (the MMA / Bluetooth SIG
// specification): a header byte carrying the high six bits of a 13-bit
// millisecond timestamp, then for every message a timestamp byte with the
// low seven bits and the message's bytes, status first (running status is
// not used: a surface that joins mid-stream reads the first message). As
// many messages as the negotiated MTU holds go in one notification, so a
// patch dump of sixty CCs is two or three packets rather than sixty
// connection intervals.

#include "midi_out.h"

#include <cinttypes>
#include <cstdint>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include "ble_midi.h"
#include "event_bus.h"

namespace {

constexpr const char *tag = "midi_out";

constexpr int queue_length  = 128; // a whole patch is about sixty messages
constexpr int task_stack    = 3072;
constexpr int task_priority = 3;

// A notification that fails for want of buffers is retried this often, for
// this long, before the packet is dropped.
constexpr int retry_ms    = 5;
constexpr int retry_limit = 40;

struct Outgoing {
    midi_message_t message;
    uint8_t except; // the source not to send it to
};

QueueHandle_t s_queue;
uint32_t s_dropped; // queue full at the producer, or the link never took it

// ---- the BLE MIDI packet ---------------------------------------------------------------------------

class BlePacket {
public:
    void begin(size_t capacity) {
        capacity_ = capacity < sizeof buffer_ ? capacity : sizeof buffer_;
        length_   = 0;
        if (capacity_ >= 1) {
            buffer_[length_++] = static_cast<uint8_t>(0x80 | ((now_ms() >> 7) & 0x3F));
        }
    }

    // False when the message does not fit; the packet is then sent and begun again.
    bool add(const midi_message_t &m) {
        const size_t needed = 2 + m.len; // timestamp, status, data
        if (length_ + needed > capacity_) {
            return false;
        }
        buffer_[length_++] = static_cast<uint8_t>(0x80 | (now_ms() & 0x7F));
        buffer_[length_++] = m.status;
        for (int i = 0; i < m.len; ++i) {
            buffer_[length_++] = m.data[i];
        }
        return true;
    }

    bool holds_messages() const {
        return length_ > 1;
    }
    const uint8_t *bytes() const {
        return buffer_;
    }
    size_t length() const {
        return length_;
    }

private:
    static uint16_t now_ms() {
        return static_cast<uint16_t>((esp_timer_get_time() / 1000) & 0x1FFF);
    }

    uint8_t buffer_[517]; // the largest MTU the peripheral offers
    size_t capacity_ = 0;
    size_t length_   = 0;
};

// Send a packet, waiting out a buffer shortage; false when the link never took it.
bool notify(const BlePacket &packet) {
    for (int attempt = 0; attempt < retry_limit; ++attempt) {
        if (ble_midi_notify(packet.bytes(), packet.length())) {
            return true;
        }
        if (!ble_midi_can_notify()) {
            return false; // the central left meanwhile
        }
        vTaskDelay(pdMS_TO_TICKS(retry_ms));
    }
    return false;
}

// ---- the task -----------------------------------------------------------------------------------------

void midi_out_task(void *) {
    Outgoing item{};
    BlePacket packet;
    while (true) {
        if (xQueueReceive(s_queue, &item, portMAX_DELAY) != pdTRUE) {
            continue;
        }
        // Everything queued goes into as few packets as fit. Without a
        // subscribed central the messages are consumed and nothing is sent:
        // nobody is listening, which is not a loss.
        const bool ble = ble_midi_can_notify();
        packet.begin(ble_midi_packet_max());
        bool more = true;
        while (more) {
            if (ble && item.except != MIDI_SOURCE_BLE && !packet.add(item.message)) {
                if (!notify(packet)) {
                    ++s_dropped;
                }
                packet.begin(ble_midi_packet_max());
                packet.add(item.message);
            }
            more = xQueueReceive(s_queue, &item, 0) == pdTRUE;
        }
        if (packet.holds_messages() && !notify(packet)) {
            ++s_dropped;
        }
        if (s_dropped) {
            ESP_LOGW(tag, "%" PRIu32 " messages dropped", s_dropped);
            s_dropped = 0;
        }
    }
}

} // namespace

void midi_out_init(void) {
    s_queue = xQueueCreate(queue_length, sizeof(Outgoing));
    if (s_queue == nullptr) {
        ESP_LOGE(tag, "failed to create the queue");
        return;
    }
    if (xTaskCreate(midi_out_task, "midi_out", task_stack, nullptr, task_priority, nullptr) != pdPASS) {
        ESP_LOGE(tag, "failed to create the task");
    }
}

void midi_out_send(const midi_message_t *message, uint8_t except) {
    if (s_queue == nullptr) {
        return;
    }
    const Outgoing item{*message, except};
    if (xQueueSend(s_queue, &item, 0) != pdTRUE) {
        ++s_dropped; // never block a producer
    }
}
