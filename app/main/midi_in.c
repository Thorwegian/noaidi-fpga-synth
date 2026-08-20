// midi_in.c — MIDI input process (UART1)
//
// Owns UART1 at 31250 baud 8N1 on the configured RX pin, feeds the
// byte stream through the MIDI parser and logs complete messages to
// the console. The only consumer of UART1.

#include "midi_in.h"

#include <stdio.h>

#include "driver/uart.h"
#include "esp_err.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

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

// ── Console decode ─────────────────────────────────────────────────
// Temporary: log parsed messages so the parser can be verified against
// the keyboard. Later this callback is where messages get pushed to
// the synth control / SPI command queue instead.

static void log_midi_msg(const midi_message_t *m, void *user)
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
            // Source gone (powered off / cable pulled): full reset and
            // dump whatever the line glitch may have left in the FIFO.
            // Note panic belongs here too once voices exist.
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
    midi_parser_init(&g_parser, log_midi_msg, NULL);

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
