// midi_in.c — MIDI input processes (UART1 = DIN, UART0 = panel)
//
// Each port owns its UART at 31250 baud 8N1 on a configured RX pin,
// feeds the byte stream through its OWN parser instance (running
// status is per-stream — two sources must never share decode state)
// and publishes complete messages to the event bus. Never prints in
// the hot path and never blocks on a consumer.
//
// Port roles (#90): UART1/GPIO0 is the DIN MIDI jack (keyboard);
// UART0/GPIO2 is the dev-host panel port, reserved for Open Stage
// Control exclusively (Thor, 2026-09-10) — test scripts stay on
// BLE/DIN so panel traffic never contends with them.

#include "midi_in.h"

#include "driver/uart.h"
#include "driver/gpio.h"
#include "esp_rom_sys.h"
#include "esp_err.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "event_bus.h"
#include "midi_parser.h"

#define MIDI_BAUD        31250
#define MIDI_RX_BUF_SIZE 256
#define MIDI_TASK_STACK  2048
#define MIDI_TASK_PRIO   5

// Silence thresholds: one MIDI byte is 320 µs at 31250 baud, so 50 ms
// is far beyond any legal inter-byte gap, and 500 ms of total silence
// means the source is gone (Active Sensing, when present, is ~200 ms).
#define MIDI_PARTIAL_TIMEOUT_MS 50
#define MIDI_SOURCE_TIMEOUT_MS  500

// ── Per-port context ───────────────────────────────────────────────
typedef struct {
    uart_port_t   uart;
    const char   *name;      // task name + log tag
    midi_parser_t parser;
    uint8_t       dbg_seen;  // first-bytes hex log budget (bring-up aid)
} midi_port_t;

static midi_port_t s_din   = { .uart = UART_NUM_1, .name = "midi_in"  };
static midi_port_t s_panel = { .uart = UART_NUM_0, .name = "midi_pnl" };

// ── Parser callback ────────────────────────────────────────────────
// Runs in the context of the port's task. Fan-out to consumers
// happens through the event bus (non-blocking), so a slow consumer
// can never stall MIDI reception.

static void midi_msg_to_bus(const midi_message_t *m, void *user)
{
    evt_t evt = {
        .kind = EVT_MIDI,
        .midi = *m,
    };
    event_bus_publish(&evt);
}

static void midi_in_task(void *arg)
{
    midi_port_t *p = (midi_port_t *)arg;
    uint8_t byte;
    uint32_t idle_ms = 0;
    bool had_traffic = false;

    while (1) {
        int n = uart_read_bytes(p->uart, &byte, 1,
                                pdMS_TO_TICKS(MIDI_PARTIAL_TIMEOUT_MS));
        if (n == 1) {
            // Bring-up aid: hex-log the first few bytes ever seen on
            // this port, so "wired but garbled" (framing/polarity) is
            // distinguishable from "nothing arrives" without a scope.
            if (p->dbg_seen < 8) {
                p->dbg_seen++;
                ESP_LOGI(p->name, "rx byte %02X", byte);
            }
            midi_parser_feed(&p->parser, byte);
            idle_ms = 0;
            had_traffic = true;
            continue;
        }

        // Silence: a message half-received before the gap can never be
        // completed by legal MIDI, so drop it. Running Status is kept
        // so spec-legal reuse across silence still decodes.
        midi_parser_reset_partial(&p->parser);

        idle_ms += MIDI_PARTIAL_TIMEOUT_MS;
        if (idle_ms >= MIDI_SOURCE_TIMEOUT_MS) {
            // Source silent: full transport reset and dump whatever the
            // line glitch may have left in the FIFO.
            //
            // Note panic belongs here too once voices exist — but only
            // if Active Sensing had been observed: a source that never
            // sends 0xFE must never be silenced by silence alone. Further,
            // after such a silence, Active Sensing must be observed again
            // before panic is re-enabled.
            midi_parser_reset(&p->parser);
            uart_flush_input(p->uart);
            idle_ms = 0;
            if (had_traffic) {
                ESP_LOGW(p->name, "MIDI source silent, parser reset");
                had_traffic = false;
            }
        }
    }
}

static void port_init(midi_port_t *p, int rx_pin)
{
    midi_parser_init(&p->parser, midi_msg_to_bus, NULL);

    uart_config_t cfg = {
        .baud_rate  = MIDI_BAUD,
        .data_bits  = UART_DATA_8_BITS,
        .parity     = UART_PARITY_DISABLE,
        .stop_bits  = UART_STOP_BITS_1,
        .flow_ctrl  = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };

    ESP_ERROR_CHECK(uart_driver_install(p->uart, MIDI_RX_BUF_SIZE, 0, 0,
                                        NULL, 0));
    ESP_ERROR_CHECK(uart_param_config(p->uart, &cfg));
    ESP_ERROR_CHECK(uart_set_pin(p->uart, UART_PIN_NO_CHANGE, rx_pin,
                                 UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));

    BaseType_t ok = xTaskCreate(midi_in_task, p->name, MIDI_TASK_STACK, p,
                                MIDI_TASK_PRIO, NULL);
    if (ok != pdPASS) {
        ESP_LOGE(p->name, "Failed to create RX task");
        return;
    }

    ESP_LOGI(p->name, "UART%d RX on GPIO%d, %d baud", (int)p->uart,
             rx_pin, MIDI_BAUD);
}

void midi_in_init(int rx_pin)
{
    port_init(&s_din, rx_pin);
}

void midi_panel_init(int rx_pin)
{
    // UART0 is free for this since the console moved wholly to the
    // USB-Serial/JTAG controller (sdkconfig: ESP_CONSOLE_UART_NUM=-1,
    // Thor 2026-09-10). RX moves to rx_pin (GPIO2 — idles high via the
    // MIDI opto, which suits the C3 strap sampling at reset); TX stays
    // on UART0's default pin, unused.
    //
    // Idle-polarity preflight: a standard MIDI-IN (opto, non-inverting)
    // idles HIGH (UART mark). Sample the pin before the UART claims it;
    // a LOW idle means either an inverting input stage or a wiring
    // problem — enable RX inversion so an inverting stage still works,
    // and say so loudly (a floating/broken line also reads low, so the
    // warning is the breadcrumb either way).
    gpio_config_t io = {
        .pin_bit_mask = 1ULL << rx_pin,
        .mode         = GPIO_MODE_INPUT,
    };
    gpio_config(&io);
    int highs = 0;
    for (int i = 0; i < 32; i++) {
        highs += gpio_get_level(rx_pin);
        esp_rom_delay_us(300);          // ~10 ms total, spans any byte
    }
    bool idle_high = highs >= 24;       // ≥75% high = healthy idle

    port_init(&s_panel, rx_pin);

    if (!idle_high) {
        ESP_ERROR_CHECK(uart_set_line_inverse(s_panel.uart,
                                              UART_SIGNAL_RXD_INV));
        ESP_LOGW(s_panel.name,
                 "line idles LOW (%d/32 high) - RX inverted; if no bytes"
                 " follow, check wiring/plug orientation", highs);
    } else {
        ESP_LOGI(s_panel.name, "line idles high (%d/32) - polarity OK",
                 highs);
    }
}
