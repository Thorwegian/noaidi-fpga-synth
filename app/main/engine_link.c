// engine_link.c — command queue → parameter image → shadow writes → swap

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
#define ENGINE_TASK_PRIO   6          // above midi_log, below midi_in
// 1 kHz control rate (Thor). Paced by an esp_timer notifying the
// task, NOT vTaskDelayUntil: the FreeRTOS tick is 100 Hz, so a 1 ms
// delay would round to 0 ticks and assert.
#define ENGINE_TICK_US     1000

#define ELEM_BASE            0x2000
#define ELEM_STRIDE          64

// GAIN word with both channels at 0xFF = exact mute (0x00000000 is
// 0 dB full volume — the classic footgun).
#define P3_MUTE            0x0000FFFFu

static QueueHandle_t s_queue;
static QueueHandle_t s_bus_queue;
static uint32_t s_image[ENGINE_NUM_ELEMENTS][ENGINE_WORDS_PER_ELEMENT];

#define BUS_BASE_ADDR      0x0800
#define BUS_QUEUE_LEN      128    // init writes 32 envelope floors +
                                  // gates in one burst
#define PROD_BASE_ADDR     0x0100
#define PROD_QUEUE_LEN     256    // 32 ADSRs x 3 words + LFOs at boot

typedef struct {
    uint16_t bus;
    uint32_t value;
} bus_cmd_t;

typedef struct {
    uint8_t  entry;
    uint8_t  word;      // 0 CFG, 1 DEPTH
    uint32_t value;
} prod_cmd_t;

static QueueHandle_t s_prod_queue;
static uint32_t s_prod[ENGINE_NUM_PRODUCERS][3];
#define PDIRTY_WORDS (ENGINE_NUM_PRODUCERS * 3 / 32)
static uint32_t s_pdirty_now[PDIRTY_WORDS];
static uint32_t s_pdirty_prev[PDIRTY_WORDS];

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
        fpga_word_write_burst(ELEM_BASE + e * ELEM_STRIDE, s_image[e],
                              ENGINE_WORDS_PER_ELEMENT);
}

static TaskHandle_t s_task;

static void tick_cb(void *arg)
{
    xTaskNotifyGive(s_task);   // runs in the esp_timer task
}

static void engine_task(void *arg)
{
    engine_cmd_t cmd;

    while (1) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);

        // Live bus writes first: no banking, no swap — straight out.
        // PACED 10 us apart: the FPGA-side mailbox is 1-deep and
        // commits in an idle slot (worst ~4 us); back-to-back writes
        // at full SPI rate can overwrite it before the commit — a
        // lost gate write is a stuck or missing note. A deeper
        // FPGA-side FIFO is the eventual fix (bus_architecture B6+).
        bus_cmd_t bc;
        while (xQueueReceive(s_bus_queue, &bc, 0) == pdTRUE) {
            fpga_word_write(BUS_BASE_ADDR + bc.bus, bc.value & 0x3FFFF);
            esp_rom_delay_us(10);
        }

        // Drain the queues into the images (elements + producers —
        // both banked, both covered by the same swap).
        bool changed = false;
        while (xQueueReceive(s_queue, &cmd, 0) == pdTRUE) {
            if (cmd.word >= ENGINE_WORDS_PER_ELEMENT)
                continue;   // elem is uint8_t: 0..255 by construction
            s_image[cmd.elem][cmd.word] = cmd.value;
            mark_dirty(cmd.elem, cmd.word);
            changed = true;
        }
        prod_cmd_t pc;
        while (xQueueReceive(s_prod_queue, &pc, 0) == pdTRUE) {
            if (pc.entry >= ENGINE_NUM_PRODUCERS || pc.word >= 3)
                continue;
            s_prod[pc.entry][pc.word] = pc.value;
            int bit = pc.entry * 3 + pc.word;
            s_pdirty_now[bit >> 5] |= 1u << (bit & 31);
            changed = true;
        }

        // Nothing new this tick and the shadow is already current
        // (nothing was written last tick either): skip write + swap.
        bool prev_any = false;
        for (int i = 0; i < DIRTY_WORDS; i++)
            if (s_dirty_prev[i]) { prev_any = true; break; }
        for (int i = 0; i < PDIRTY_WORDS; i++)
            if (s_pdirty_prev[i]) { prev_any = true; break; }
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
                fpga_word_write(ELEM_BASE + elem * ELEM_STRIDE + word,
                                s_image[elem][word]);
            }
        }
        for (int i = 0; i < PDIRTY_WORDS; i++) {
            uint32_t bits = s_pdirty_now[i] | s_pdirty_prev[i];
            while (bits) {
                int b = __builtin_ctz(bits);
                bits &= bits - 1;
                int idx = i * 32 + b;              // entry*3 + word
                fpga_word_write(PROD_BASE_ADDR + (idx / 3) * 4 + idx % 3,
                                s_prod[idx / 3][idx % 3]);
            }
        }
        fpga_swap();

        memcpy(s_dirty_prev, s_dirty_now, sizeof(s_dirty_prev));
        memset(s_dirty_now, 0, sizeof(s_dirty_now));
        memcpy(s_pdirty_prev, s_pdirty_now, sizeof(s_pdirty_prev));
        memset(s_pdirty_now, 0, sizeof(s_pdirty_now));

        if (s_drops) {
            ESP_LOGW(TAG, "queue full, dropped %" PRIu32 " commands", s_drops);
            s_drops = 0;
        }
    }
}

void engine_link_init(void)
{
    // Image: every element gated off (and gain-muted for belt and
    // braces at boot), benign params otherwise. Every element's
    // cutoff pointer targets bus 1 (the global cutoff-offset bus the
    // mod wheel drives); all other pointers stay on bus 0 (zero).
    for (int e = 0; e < ENGINE_NUM_ELEMENTS; e++) {
        s_image[e][0] = 0;
        s_image[e][1] = 0;
        s_image[e][2] = 0x40000000;   // q1 = 1.0, fc = 0
        s_image[e][3] = P3_MUTE;
        s_image[e][4] = 0;            // GATE off
        s_image[e][5] = 0;            // PTRS0: all → bus 0 (none);
        s_image[e][6] = 0;            // PTRS1: voice_alloc owns the plan
    }

    // Both banks get the muted image before anything can play.
    write_full_image();
    fpga_swap();
    write_full_image();
    fpga_swap();
    ESP_LOGI(TAG, "both banks muted (%d elements)", ENGINE_NUM_ELEMENTS);

    s_queue = xQueueCreate(ENGINE_QUEUE_LEN, sizeof(engine_cmd_t));
    s_bus_queue = xQueueCreate(BUS_QUEUE_LEN, sizeof(bus_cmd_t));
    s_prod_queue = xQueueCreate(PROD_QUEUE_LEN, sizeof(prod_cmd_t));
    if (s_queue == NULL || s_bus_queue == NULL || s_prod_queue == NULL) {
        ESP_LOGE(TAG, "failed to create command queues");
        return;
    }

    if (xTaskCreate(engine_task, "engine_link", ENGINE_TASK_STACK, NULL,
                    ENGINE_TASK_PRIO, &s_task) != pdPASS) {
        ESP_LOGE(TAG, "failed to create task");
        return;
    }

    const esp_timer_create_args_t targs = {
        .callback = tick_cb, .name = "engine_tick",
    };
    esp_timer_handle_t timer;
    ESP_ERROR_CHECK(esp_timer_create(&targs, &timer));
    ESP_ERROR_CHECK(esp_timer_start_periodic(timer, ENGINE_TICK_US));
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

bool engine_link_bus_write(uint16_t bus, uint32_t value_q810)
{
    if (s_bus_queue == NULL || bus == 0 || bus >= 1024)
        return false;
    bus_cmd_t bc = {.bus = bus, .value = value_q810};
    if (xQueueSend(s_bus_queue, &bc, 0) != pdTRUE) {
        s_drops++;
        return false;
    }
    return true;
}

bool engine_link_prod_write(uint8_t entry, uint8_t word, uint32_t value)
{
    if (s_prod_queue == NULL || entry >= ENGINE_NUM_PRODUCERS || word >= 3)
        return false;
    prod_cmd_t pc = {.entry = entry, .word = word, .value = value};
    if (xQueueSend(s_prod_queue, &pc, 0) != pdTRUE) {
        s_drops++;
        return false;
    }
    return true;
}
