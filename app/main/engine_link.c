// engine_link.c — command queue → parameter image → shadow writes → swap
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "engine_link.h"

#include <inttypes.h>
#include <string.h>

#include "esp_log.h"
#include "esp_rom_sys.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include "spi_regs.h"

#define TAG "engine_link"

#define ENGINE_QUEUE_LEN   1024   // voice_alloc's boot-time pointer
                                  // push alone is 512 commands
#define ENGINE_TASK_STACK  3072
#define ENGINE_TASK_PRIO   6          // highest app task: above midi_in/
                                      // voice_alloc (5), midi_log/ble_rx (4)
// 1 kHz control rate. Paced by an esp_timer notifying the task, so the
// rate does not depend on the FreeRTOS tick (CONFIG_FREERTOS_HZ, pinned
// to 1000 in sdkconfig.defaults).
#define ENGINE_TICK_US     1000

#define ELEM_BASE            0x2000
#define ELEM_STRIDE          64

// GAIN word with both channels at 0x00 = exact mute (volume
// semantics: 0xFF is loudest).
#define GAIN_WORD_MUTE            0x00000000u

static QueueHandle_t s_queue;
static QueueHandle_t s_dmem_queue;
static uint32_t s_param_image[ENGINE_NUM_ELEMENTS][ENGINE_WORDS_PER_ELEMENT];

#define DMEM_BASE_ADDR      0x0800
#define DMEM_QUEUE_LEN      128    // init writes 32 envelope floors +
                                  // 4 global buses in one burst
#define IMEM_BASE_ADDR     0x0100
#define IMEM_QUEUE_LEN     512    // boot burst: 2 LFOs (2 words each)
                                  // + 32 MOD envs + 32 amp ADSRs (4
                                  // words each) + 32 fan-out sources
                                  // (2 words) = 324 pushes before the
                                  // 1 kHz tick can drain. A 256-deep
                                  // queue drops the tail = the last
                                  // voices' amp-env configs = gain
                                  // floor forever = heard as the level
                                  // dropping every 32 note-ons.
                                  // Headroom ~1.6x.

typedef struct {
    uint16_t dmem_addr;
    uint32_t value;
} dmem_cmd_t;

typedef struct {
    uint8_t  entry;
    uint8_t  word;      // 0 CFG, 1 RATES, 2 DEPTH, 3 RATES2
    uint32_t value;
} imem_cmd_t;

static QueueHandle_t s_imem_queue;
static uint32_t s_imem_image[ENGINE_NUM_INSTR][4];   // word 3 is the second
                                                   // ADSR rate word
#define IMEM_DIRTY_WORDS (ENGINE_NUM_INSTR * 4 / 32)
static uint32_t s_imem_dirty_now[IMEM_DIRTY_WORDS];
static uint32_t s_imem_dirty_prev[IMEM_DIRTY_WORDS];

// Dirty bitmaps, one bit per (elem, word): 1792 bits.
#define DIRTY_WORDS (ENGINE_NUM_ELEMENTS * ENGINE_WORDS_PER_ELEMENT / 32)
static uint32_t s_dirty_now[DIRTY_WORDS];   // changed since last swap
static uint32_t s_dirty_prev[DIRTY_WORDS];  // written before last swap


static inline void mark_dirty(int elem, int word)
{
    int bit = elem * ENGINE_WORDS_PER_ELEMENT + word;
    s_dirty_now[bit >> 5] |= 1u << (bit & 31);
}

// Write every image word to the current shadow bank. Boot-time only.
static void write_full_image(void)
{
    for (int e = 0; e < ENGINE_NUM_ELEMENTS; e++)
        fpga_word_write_burst(ELEM_BASE + e * ELEM_STRIDE, s_param_image[e],
                              ENGINE_WORDS_PER_ELEMENT);
}

static TaskHandle_t s_task;

static void tick_timer_cb(void *arg)
{
    xTaskNotifyGive(s_task);   // runs in the esp_timer task
}

static void engine_task(void *arg)
{
    engine_param_cmd_t cmd;

    while (1) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        int64_t wake0 = esp_timer_get_time();

        // Live bus writes first: no banking, no swap — straight out.
        // No pacing needed: at 10 MHz one SPI word occupies the wire
        // for 5.6 us, longer than the mailbox's worst-case commit
        // wait (~3.6 us), so back-to-back writes cannot overrun the
        // 1-deep mailbox. (The stuck notes were a gateware
        // pending-clear bug, not an overrun.)
        dmem_cmd_t bc;
        while (xQueueReceive(s_dmem_queue, &bc, 0) == pdTRUE)
            fpga_word_write(DMEM_BASE_ADDR + bc.dmem_addr, bc.value & 0x3FFFF);

        // Drain the queues into the images (elements + producers —
        // both banked, both covered by the same swap).
        bool changed = false;
        while (xQueueReceive(s_queue, &cmd, 0) == pdTRUE) {
            if (cmd.word >= ENGINE_WORDS_PER_ELEMENT)
                continue;   // elem is uint8_t: 0..255 by construction
            // No-op elision, so the cost tracks what actually changed:
            // the image IS the FPGA's state (the FPGA-reload → ESP-
            // reboot rule guarantees it), so a write of the value
            // already there is pure waste. render_voice re-renders
            // resend every word; skipping the unchanged ones turns a
            // one-knob re-render's flush from all 256 rows (~15 ms of
            // SPI, enough to wedge the link) into just the touched
            // rows.
            if (s_param_image[cmd.elem][cmd.word] == cmd.value)
                continue;
            s_param_image[cmd.elem][cmd.word] = cmd.value;
            mark_dirty(cmd.elem, cmd.word);
            changed = true;
        }
        imem_cmd_t pc;
        while (xQueueReceive(s_imem_queue, &pc, 0) == pdTRUE) {
            // entry is uint8_t = 0..255 — exactly the pool size, so
            // the type IS the bound
            if (pc.word >= 4)
                continue;
            if (s_imem_image[pc.entry][pc.word] == pc.value)   // no-op elision
                continue;
            s_imem_image[pc.entry][pc.word] = pc.value;
            int bit = pc.entry * 4 + pc.word;
            s_imem_dirty_now[bit >> 5] |= 1u << (bit & 31);
            changed = true;
        }

        // Nothing new this tick and the shadow is already current
        // (nothing was written last tick either): skip write + swap.
        bool prev_any = false;
        for (int i = 0; i < DIRTY_WORDS; i++)
            if (s_dirty_prev[i]) { prev_any = true; break; }
        for (int i = 0; i < IMEM_DIRTY_WORDS; i++)
            if (s_imem_dirty_prev[i]) { prev_any = true; break; }
        if (!changed && !prev_any)
            continue;

        // Write dirty_now ∪ dirty_prev to the shadow, then swap. Burst
        // the WHOLE element row (7 consecutive words, one CS-framed
        // transaction) whenever any of its words changed. The ESP-IDF
        // SPI-master driver cost is per-TRANSACTION (bus lock, ISR,
        // semaphore), so sending word by word would turn a re-render
        // into hundreds of transactions and pin this task until the
        // watchdog fires. Untouched words in the row are already
        // current in s_param_image, so re-sending them is free.
        for (int e = 0; e < ENGINE_NUM_ELEMENTS; e++) {
            bool row_dirty = false;
            for (int w = 0; w < ENGINE_WORDS_PER_ELEMENT; w++) {
                int bit = e * ENGINE_WORDS_PER_ELEMENT + w;
                if ((s_dirty_now[bit >> 5] | s_dirty_prev[bit >> 5])
                        & (1u << (bit & 31))) {
                    row_dirty = true;
                    break;
                }
            }
            if (row_dirty)
                fpga_word_write_burst(ELEM_BASE + e * ELEM_STRIDE,
                                      s_param_image[e], ENGINE_WORDS_PER_ELEMENT);
        }
        for (int i = 0; i < IMEM_DIRTY_WORDS; i++) {
            uint32_t bits = s_imem_dirty_now[i] | s_imem_dirty_prev[i];
            while (bits) {
                int b = __builtin_ctz(bits);
                bits &= bits - 1;
                int idx = i * 32 + b;              // entry*4 + word
                // four words per entry and a stride of four, so the
                // producer address IS the bit index
                fpga_word_write(IMEM_BASE_ADDR + idx,
                                s_imem_image[idx / 4][idx % 4]);
            }
        }
        fpga_swap();

        memcpy(s_dirty_prev, s_dirty_now, sizeof(s_dirty_prev));
        memset(s_dirty_now, 0, sizeof(s_dirty_now));
        memcpy(s_imem_dirty_prev, s_imem_dirty_now, sizeof(s_imem_dirty_prev));
        memset(s_imem_dirty_now, 0, sizeof(s_imem_dirty_now));

        // Single-core guard. If this wake ran long (a flood of
        // dirty rows to burst over SPI), the 1 kHz notify is already
        // pending, so the ulTaskNotifyTake above would return at once
        // and we would never block — starving IDLE (priority 0) on this
        // one-core chip → task watchdog. Yield a tick so IDLE runs; the
        // SPI image lags at most ~1 ms, which is inaudible.
        if (esp_timer_get_time() - wake0 > 800)
            vTaskDelay(1);
    }
}

void engine_link_init(void)
{
    // Image: every element gated off (and gain-muted for belt and
    // braces at boot), benign params otherwise. ALL pointers start on
    // bus 0 (the zero bus) — voice_alloc owns the plan and repoints
    // at note-on. The wheel rides DMEM_CH_CUT.
    for (int e = 0; e < ENGINE_NUM_ELEMENTS; e++) {
        s_param_image[e][0] = 0;
        s_param_image[e][1] = 0;
        s_param_image[e][2] = 0;            // Butterworth, fc = 0
        s_param_image[e][3] = GAIN_WORD_MUTE;
        s_param_image[e][4] = 0;            // GATE off
        s_param_image[e][5] = 0;            // PTRS0: all → bus 0 (none);
        s_param_image[e][6] = 0;            // PTRS1: voice_alloc owns the plan
    }

    // Both banks get the muted image before anything can play.
    write_full_image();
    fpga_swap();
    write_full_image();
    fpga_swap();
    ESP_LOGI(TAG, "both banks muted (%d elements)", ENGINE_NUM_ELEMENTS);

    s_queue = xQueueCreate(ENGINE_QUEUE_LEN, sizeof(engine_param_cmd_t));
    s_dmem_queue = xQueueCreate(DMEM_QUEUE_LEN, sizeof(dmem_cmd_t));
    s_imem_queue = xQueueCreate(IMEM_QUEUE_LEN, sizeof(imem_cmd_t));
    if (s_queue == NULL || s_dmem_queue == NULL || s_imem_queue == NULL) {
        ESP_LOGE(TAG, "failed to create command queues");
        return;
    }

    if (xTaskCreate(engine_task, "engine_link", ENGINE_TASK_STACK, NULL,
                    ENGINE_TASK_PRIO, &s_task) != pdPASS) {
        ESP_LOGE(TAG, "failed to create task");
        return;
    }

    const esp_timer_create_args_t targs = {
        .callback = tick_timer_cb, .name = "engine_tick",
    };
    esp_timer_handle_t timer;
    ESP_ERROR_CHECK(esp_timer_create(&targs, &timer));
    ESP_ERROR_CHECK(esp_timer_start_periodic(timer, ENGINE_TICK_US));
    ESP_LOGI(TAG, "1 kHz tick running");
}

bool engine_link_param_write(const engine_param_cmd_t *cmd)
{
    if (s_queue == NULL)
        return false;
    return xQueueSend(s_queue, cmd, 0) == pdTRUE;
}

bool engine_link_dmem_write(uint16_t dmem_addr, uint32_t value_q810)
{
    if (s_dmem_queue == NULL || dmem_addr == 0 || dmem_addr >= 1024)
        return false;
    dmem_cmd_t bc = {.dmem_addr = dmem_addr, .value = value_q810};
    return xQueueSend(s_dmem_queue, &bc, 0) == pdTRUE;
}

bool engine_link_imem_write(uint8_t entry, uint8_t word, uint32_t value)
{
    if (s_imem_queue == NULL || word >= 4)   // uint8_t entry spans the pool
        return false;
    imem_cmd_t pc = {.entry = entry, .word = word, .value = value};
    return xQueueSend(s_imem_queue, &pc, 0) == pdTRUE;
}
