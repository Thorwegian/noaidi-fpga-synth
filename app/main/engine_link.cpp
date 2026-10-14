// engine_link.cpp — the register image → the write queue → the swap
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "engine_link.h"

#include <algorithm>
#include <array>
#include <bitset>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "csp/control_program.hpp"
#include "engine_image.hpp"
#include "fpga_map.hpp"
#include "render.hpp"
#include "spi_regs.h"

namespace {

constexpr const char *tag = "engine_link";

constexpr int task_stack = 4096;
// highest app task: above midi_in/voice_alloc (5), midi_log/ble_rx (4)
constexpr int task_priority = 6;
// 1 kHz control rate. Paced by an esp_timer notifying the task, so the rate
// does not depend on the FreeRTOS tick (CONFIG_FREERTOS_HZ, pinned to 1000
// in sdkconfig.defaults).
constexpr int64_t tick_us = 1000;

// The FPGA's queue holds 512 writes and the CSP applies 48 a pass: 48 passes
// in a tick, so a tick can send nearly the whole queue and it is empty again
// by the next. A tick sends no more than this, the rest waits for the next.
constexpr int writes_per_tick = 480;

// The SPI link, as the image sends through it.
class SpiPort : public EnginePort {
public:
    void queue_burst(uint16_t address, const uint32_t *words,
                     int count) override {
        fpga_word_write_burst(address, words, static_cast<size_t>(count));
    }
    void write_register(uint16_t address, uint32_t value) override {
        fpga_word_write(address, value);
    }
};

EngineImage image;
SpiPort port;
SemaphoreHandle_t lock = nullptr;
TaskHandle_t task      = nullptr;
bool test_tone         = false;
bool running           = false;

uint32_t ctrl_word(uint32_t bits) {
    return bits | (test_tone ? fpga_map::ctrl_test_tone : 0);
}

// Send what is pending, at most `limit` words, and commit it with a swap.
int send(int limit, uint32_t ctrl_bits) {
    return image.send(port, limit, ctrl_word(ctrl_bits));
}

void tick_timer_cb(void *) {
    xTaskNotifyGive(task); // runs in the esp_timer task
}

void engine_task(void *) {
    while (true) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        const int64_t woke = esp_timer_get_time();

        xSemaphoreTake(lock, portMAX_DELAY);
        send(writes_per_tick, 0);
        xSemaphoreGive(lock);

        // Single-core guard. If this wake ran long, the 1 kHz notify is
        // already pending, so the ulTaskNotifyTake above would return at once
        // and we would never block: starving IDLE (priority 0) on this
        // one-core chip, and the task watchdog with it. Yield a tick so IDLE
        // runs; the image lags at most a millisecond or two, which is
        // inaudible.
        if (esp_timer_get_time() - woke > 800) {
            vTaskDelay(1);
        }
    }
}

// Load the control program while the CSP is held.
void load_program() {
    uint32_t high = 0xFFFFFFFF; // none yet
    for (size_t pc = 0; pc < csp::control::words.size(); ++pc) {
        const uint64_t word = csp::control::words[pc];
        if (static_cast<uint32_t>(word >> 32) != high) {
            high = static_cast<uint32_t>(word >> 32);
            fpga_word_write(fpga_map::program_high, high);
        }
        fpga_word_write(static_cast<uint16_t>(fpga_map::program_base + pc),
                        static_cast<uint32_t>(word));
    }
}

} // namespace

void engine_link_init(void) {
    lock = xSemaphoreCreateMutex();
    if (lock == nullptr) {
        ESP_LOGE(tag, "no mutex");
        return;
    }

    // The CSP starts held; make sure of it, whatever the last run left, then
    // give it the program, the constants and the wiring.
    fpga_word_write(fpga_map::ctrl, fpga_map::ctrl_hold);
    load_program();

    render::Writes writes;
    for (const csp::control::Constant &constant : csp::control::constants) {
        writes.push_back({constant.address, constant.raw});
    }
    render::setup(writes);
    for (const render::Write &write : writes) {
        image.set(write.address, write.raw);
    }
    // Held, the CSP applies every committed write in one pass; the queue holds
    // 512, so a chunk at a time, and a pass between.
    while (image.pending()) {
        send(fpga_map::queue_depth / 2, fpga_map::ctrl_hold);
        vTaskDelay(pdMS_TO_TICKS(2));
    }
    fpga_word_write(fpga_map::ctrl, ctrl_word(0)); // release
    ESP_LOGI(tag, "control program loaded: %u instructions, %u constants",
             static_cast<unsigned>(csp::control::words.size()),
             static_cast<unsigned>(csp::control::constants.size()));

    if (xTaskCreate(engine_task, "engine_link", task_stack, nullptr,
                    task_priority, &task)
        != pdPASS) {
        ESP_LOGE(tag, "failed to create task");
        return;
    }
    esp_timer_create_args_t timer_args = {};
    timer_args.callback                = tick_timer_cb;
    timer_args.name                    = "engine_tick";
    esp_timer_handle_t timer;
    ESP_ERROR_CHECK(esp_timer_create(&timer_args, &timer));
    ESP_ERROR_CHECK(esp_timer_start_periodic(timer, tick_us));
    running = true;
    ESP_LOGI(tag, "1 kHz tick running");
}

bool engine_link_write(int address, int32_t raw) {
    if (!running) {
        return false;
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    const bool ok = image.set(address, raw);
    xSemaphoreGive(lock);
    return ok;
}

bool engine_link_write_all(const render::Writes &writes) {
    if (!running) {
        return false;
    }
    bool ok = true;
    xSemaphoreTake(lock, portMAX_DELAY);
    for (const render::Write &write : writes) {
        ok &= image.set(write.address, write.raw, write.force);
    }
    xSemaphoreGive(lock);
    return ok;
}

bool engine_link_point(int partial, const int *pointers) {
    if (!running || partial < 0 || partial >= fpga_map::partial_count) {
        return false;
    }
    // Three pointers of ten bits to a word, the fourth word commits.
    std::array<uint32_t, fpga_map::pointer_words> words{};
    for (int k = 0; k < render::pointer_count; ++k) {
        words[k / 3] |= (static_cast<uint32_t>(pointers[k]) & 0x3FF)
                        << (10 * (k % 3));
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    fpga_word_write_burst(fpga_map::partial_base
                                  + partial * fpga_map::partial_stride,
                          words.data(), fpga_map::pointer_words);
    xSemaphoreGive(lock);
    return true;
}

void engine_link_test_tone(bool on) {
    if (!running) {
        return;
    }
    xSemaphoreTake(lock, portMAX_DELAY);
    test_tone = on;
    fpga_word_write(fpga_map::ctrl, ctrl_word(0));
    xSemaphoreGive(lock);
}
