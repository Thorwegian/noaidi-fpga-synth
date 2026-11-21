// usb_midi.cpp — the synth as a USB MIDI device (see usb_midi.h)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The socket marked USB is the chip's USB-OTG controller. TinyUSB brings the
// interface up as one MIDI 1.0 function: bulk OUT for the host's bytes, bulk
// IN for the synth's.
//
// The input side keeps a parser instance of its own (midi_parser.h): running
// status belongs to a stream, and the silence rules of the DIN inputs do not
// belong here at all — a USB stream has no Active Sensing to send, and a
// message cannot be cut in half across a packet boundary, so nothing resets
// this parser but the start of the firmware.
//
// The output side is the same queue the BLE surface reads (midi_out.cpp):
// parameter feedback, never what arrived.

#include "usb_midi.h"

#include <cstddef>
#include <cstdint>

#include "class/audio/audio.h"
#include "esp_log.h"
#include "tinyusb.h"
#include "tusb.h"

#include "event_bus.h"
#include "midi_parser.h"
#include "midi_sysex.h"

namespace {

constexpr char tag[] = "usb_midi";

// ── Descriptors ────────────────────────────────────────────────────
// Full speed only (the S3's OTG controller runs here at 12 Mbit/s): the
// audio control interface and the MIDI streaming interface of one MIDI 1.0
// function, with a 64-byte bulk endpoint each way.
enum {
    ITF_NUM_MIDI = 0,
    ITF_NUM_MIDI_STREAMING,
    ITF_NUM_TOTAL,
};

constexpr uint8_t kEndpointOut = 0x01;
constexpr uint8_t kEndpointIn  = 0x82; // includes the IN direction bit
constexpr uint16_t kConfigurationLength =
        TUD_CONFIG_DESC_LEN + TUD_MIDI_DESC_LEN;

const uint8_t kConfiguration[] = {
        TUD_CONFIG_DESCRIPTOR(1, ITF_NUM_TOTAL, 0, kConfigurationLength, 0x00,
                              100),
        TUD_MIDI_DESCRIPTOR(ITF_NUM_MIDI, 0, kEndpointOut, kEndpointIn, 64),
};

const tusb_desc_device_t kDevice = {
        .bLength            = sizeof(tusb_desc_device_t),
        .bDescriptorType    = TUSB_DESC_DEVICE,
        .bcdUSB             = 0x0200,
        .bDeviceClass       = 0x00,
        .bDeviceSubClass    = 0x00,
        .bDeviceProtocol    = 0x00,
        .bMaxPacketSize0    = CFG_TUD_ENDPOINT0_SIZE,
        .idVendor           = 0xCafe, // a bring-up ID; the product's own is a decision
        .idProduct          = 0x4015,
        .bcdDevice          = 0x0100,
        .iManufacturer      = 0x01,
        .iProduct           = 0x02,
        .iSerialNumber      = 0x03,
        .bNumConfigurations = 0x01,
};

// Index 0 is the language ID; the serial index is left NULL, and esp_tinyusb
// fills it with the chip's MAC, so the port keeps its identity across flashes.
const char *kStrings[] = {
        "\x09\x04", "Noaidi", "Noaidi MIDI", nullptr,
};

// ── The incoming stream ────────────────────────────────────────────
midi_parser_t s_parser;

void publish_message(const midi_message_t *message, void *user) {
    (void) user;
    evt_t evt = {};
    evt.kind   = EVT_MIDI;
    evt.source = MIDI_SOURCE_USB;
    evt.midi   = *message;
    event_bus_publish(&evt);
}

void publish_sysex(const uint8_t *payload, uint8_t length, void *user) {
    (void) user;
    midi_sysex_received(payload, length, MIDI_SOURCE_USB);
}

// The host's attach and detach, as the device sees them. esp_tinyusb's own
// tud_mount_cb turns these into the device's events.
void on_device_event(tinyusb_event_t *event, void *arg) {
    (void) arg;
    switch (event->id) {
    case TINYUSB_EVENT_ATTACHED:
        ESP_LOGI(tag, "host attached the bus");
        break;
    case TINYUSB_EVENT_DETACHED:
        ESP_LOGI(tag, "host detached the bus");
        break;
    default:
        break;
    }
}

} // namespace

// ── TinyUSB callbacks ──────────────────────────────────────────────
extern "C" void tud_midi_rx_cb(uint8_t itf) {
    (void) itf;
    uint8_t bytes[64];
    while (tud_midi_available() > 0) {
        const uint32_t got = tud_midi_stream_read(bytes, sizeof bytes);
        if (got == 0) {
            break;
        }
        for (uint32_t i = 0; i < got; ++i) {
            midi_parser_feed(&s_parser, bytes[i]);
        }
    }
}

// ── The API ────────────────────────────────────────────────────────
void usb_midi_init(void) {
    midi_parser_init(&s_parser, publish_message, nullptr);
    midi_parser_on_sysex(&s_parser, publish_sysex);

    tinyusb_config_t config = {};
    config.port                  = TINYUSB_PORT_FULL_SPEED_0;
    config.task.size             = 4096;
    config.task.priority         = 5;
    config.task.xCoreID          = 0; // the one core the firmware uses
    config.descriptor.device     = &kDevice;
    config.descriptor.string     = kStrings;
    config.descriptor.string_count =
            static_cast<int>(sizeof kStrings / sizeof kStrings[0]);
    config.descriptor.full_speed_config = kConfiguration;
    config.event_cb              = on_device_event;

    const esp_err_t err = tinyusb_driver_install(&config);
    if (err != ESP_OK) {
        ESP_LOGE(tag, "device stack not installed: %s", esp_err_to_name(err));
        return;
    }
    ESP_LOGI(tag, "device stack up");
}

bool usb_midi_connected(void) {
    return tud_midi_mounted();
}

void usb_midi_send(const uint8_t *bytes, size_t length) {
    if (length == 0 || !tud_midi_mounted()) {
        return;
    }
    tud_midi_stream_write(0, bytes, length);
}
