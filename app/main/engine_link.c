// engine_link.c — command queue → parameter image → shadow writes → swap

#include "engine_link.h"

#include <inttypes.h>
#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include "spi_regs.h"

#define TAG "engine_link"

#define ENGINE_QUEUE_LEN   512
#define ENGINE_TASK_STACK  3072
#define ENGINE_TASK_PRIO   6          // above midi_log, below midi_in
#define ENGINE_TICK_MS     1          // 1 kHz control rate (Thor)

#define PV_BASE            0x2000
#define PV_STRIDE          64

// GAIN word with both channels at 0xFF = exact mute (0x00000000 is
// 0 dB full volume — the classic footgun).
#define P3_MUTE            0x0000FFFFu

static QueueHandle_t s_queue;
static uint32_t s_image[ENGINE_NUM_ELEMENTS][ENGINE_WORDS_PER_ELEMENT];

// Dirty bitmaps, one bit per (elem, word): 1024 bits.
#define DIRTY_WORDS (ENGINE_NUM_ELEMENTS * ENGINE_WORDS_PER_ELEMENT / 32)
static uint32_t s_dirty_now[DIRTY_WORDS];   // changed since last swap
static uint32_t s_dirty_prev[DIRTY_WORDS];  // written before last swap

static uint32_t s_drops;

static inline void mark_dirty(int elem, int word)
{
    int bit = elem * ENGINE_WORDS_PER_ELEMENT + word;
    s_dirty_now[bit >> 5] |= 1u << (bit & 31);
}

// Write every image word to the current shadow bank. Boot-time only.
static void write_full_image(void)
{
    for (int e = 0; e < ENGINE_NUM_ELEMENTS; e++)
        fpga_word_write_burst(PV_BASE + e * PV_STRIDE, s_image[e],
                              ENGINE_WORDS_PER_ELEMENT);
}

static void engine_task(void *arg)
{
    engine_cmd_t cmd;
    TickType_t wake = xTaskGetTickCount();

    while (1) {
        vTaskDelayUntil(&wake, pdMS_TO_TICKS(ENGINE_TICK_MS));

        // Drain the queue into the image.
        bool changed = false;
        while (xQueueReceive(s_queue, &cmd, 0) == pdTRUE) {
            if (cmd.word >= ENGINE_WORDS_PER_ELEMENT)
                continue;   // elem is uint8_t: 0..255 by construction
            s_image[cmd.elem][cmd.word] = cmd.value;
            mark_dirty(cmd.elem, cmd.word);
            changed = true;
        }

        // Nothing new this tick and the shadow is already current
        // (nothing was written last tick either): skip write + swap.
        bool prev_any = false;
        for (int i = 0; i < DIRTY_WORDS; i++)
            if (s_dirty_prev[i]) { prev_any = true; break; }
        if (!changed && !prev_any)
            continue;

        // Write dirty_now ∪ dirty_prev to the shadow, then swap.
        for (int i = 0; i < DIRTY_WORDS; i++) {
            uint32_t bits = s_dirty_now[i] | s_dirty_prev[i];
            while (bits) {
                int b = __builtin_ctz(bits);
                bits &= bits - 1;
                int idx  = i * 32 + b;
                int elem = idx / ENGINE_WORDS_PER_ELEMENT;
                int word = idx % ENGINE_WORDS_PER_ELEMENT;
                fpga_word_write(PV_BASE + elem * PV_STRIDE + word,
                                s_image[elem][word]);
            }
        }
        fpga_swap();

        memcpy(s_dirty_prev, s_dirty_now, sizeof(s_dirty_prev));
        memset(s_dirty_now, 0, sizeof(s_dirty_now));

        if (s_drops) {
            ESP_LOGW(TAG, "queue full, dropped %" PRIu32 " commands", s_drops);
            s_drops = 0;
        }
    }
}

void engine_link_init(void)
{
    // Image: every element muted, benign params otherwise.
    for (int e = 0; e < ENGINE_NUM_ELEMENTS; e++) {
        s_image[e][0] = 0;
        s_image[e][1] = 0;
        s_image[e][2] = 0x40000000;   // q1 = 1.0, fc = 0
        s_image[e][3] = P3_MUTE;
    }

    // Both banks get the muted image before anything can play.
    write_full_image();
    fpga_swap();
    write_full_image();
    fpga_swap();
    ESP_LOGI(TAG, "both banks muted (%d elements)", ENGINE_NUM_ELEMENTS);

    s_queue = xQueueCreate(ENGINE_QUEUE_LEN, sizeof(engine_cmd_t));
    if (s_queue == NULL) {
        ESP_LOGE(TAG, "failed to create command queue");
        return;
    }

    if (xTaskCreate(engine_task, "engine_link", ENGINE_TASK_STACK, NULL,
                    ENGINE_TASK_PRIO, NULL) != pdPASS) {
        ESP_LOGE(TAG, "failed to create task");
        return;
    }
    ESP_LOGI(TAG, "1 kHz tick running");
}

bool engine_link_send(const engine_cmd_t *cmd)
{
    if (s_queue == NULL)
        return false;
    if (xQueueSend(s_queue, cmd, 0) != pdTRUE) {
        s_drops++;
        return false;
    }
    return true;
}
