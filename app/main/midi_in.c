// midi_in.c — MIDI input process (UART1)
//
// Owns UART1 at 31250 baud 8N1 on the configured RX pin, feeds the
// byte stream through the MIDI parser and publishes complete messages
// to the event bus. Never prints and never blocks on a consumer.

#include "midi_in.h"

#include "driver/uart.h"
#include "esp_err.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "event_bus.h"
#include "midi_parser.h"

#define MIDI_UART_PORT   UART_NUM_1
#define MIDI_BAUD        31250
#define MIDI_RX_BUF_SIZE 256
#define MIDI_TASK_STACK  2048
#define MIDI_TASK_PRIO   5

// Silence thresholds: one MIDI byte is 320 µs at 31250 baud, so 50 ms
// is far beyond any legal inter-byte gap, and 500 ms of total silence
// means the source is gone (Active Sensing, when present, is ~200 ms).
#define MIDI_PARTIAL_TIMEOUT_MS 50
#define MIDI_SOURCE_TIMEOUT_MS  500

// ── Parser callback ────────────────────────────────────────────────
// Runs in the context of the midi_in task. Fan-out to consumers
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

static midi_parser_t g_parser;

static void midi_in_task(void *arg)
{
    uint8_t byte;
    uint32_t idle_ms = 0;
    bool had_traffic = false;

    while (1) {
        int n = uart_read_bytes(MIDI_UART_PORT, &byte, 1,
                                pdMS_TO_TICKS(MIDI_PARTIAL_TIMEOUT_MS));
        if (n == 1) {
            midi_parser_feed(&g_parser, byte);
            idle_ms = 0;
            had_traffic = true;
            continue;
        }

        // Silence: a message half-received before the gap can never be
        // completed by legal MIDI, so drop it. Running Status is kept
        // so spec-legal reuse across silence still decodes.
        midi_parser_reset_partial(&g_parser);

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
            midi_parser_reset(&g_parser);
            uart_flush_input(MIDI_UART_PORT);
            idle_ms = 0;
            if (had_traffic) {
                ESP_LOGW("midi_in", "MIDI source silent, parser reset");
                had_traffic = false;
            }
        }
    }
}

void midi_in_init(int rx_pin)
{
    midi_parser_init(&g_parser, midi_msg_to_bus, NULL);

    uart_config_t cfg = {
        .baud_rate  = MIDI_BAUD,
        .data_bits  = UART_DATA_8_BITS,
        .parity     = UART_PARITY_DISABLE,
        .stop_bits  = UART_STOP_BITS_1,
        .flow_ctrl  = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };

    ESP_ERROR_CHECK(uart_driver_install(MIDI_UART_PORT, MIDI_RX_BUF_SIZE, 0, 0,
                                        NULL, 0));
    ESP_ERROR_CHECK(uart_param_config(MIDI_UART_PORT, &cfg));
    ESP_ERROR_CHECK(uart_set_pin(MIDI_UART_PORT, UART_PIN_NO_CHANGE, rx_pin,
                                 UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));

    BaseType_t ok = xTaskCreate(midi_in_task, "midi_in", MIDI_TASK_STACK, NULL,
                                MIDI_TASK_PRIO, NULL);
    if (ok != pdPASS) {
        ESP_LOGE("midi_in", "Failed to create RX task");
        return;
    }

    ESP_LOGI("midi_in", "UART1 RX on GPIO%d, %d baud", rx_pin, MIDI_BAUD);
}
