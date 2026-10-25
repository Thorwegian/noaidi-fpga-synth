// probe_main.cpp — a hardware probe for ESP32-S3 boards of unknown make
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Prints, on the UART0 console: the chip and memory, the strapping pins,
// a pull-up / pull-down scan of every GPIO the module leaves free (what the
// board drives or pulls shows as the same level under both pulls), PSRAM
// bandwidth, a Wi-Fi scan, and then a WS2812 sequence on each of the pins
// the official DevKitC-1 uses for its RGB LED (GPIO48 on v1.0, GPIO38 on
// v1.1), told apart by their patterns, for a person watching the board.

#include <array>
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <vector>

#include "driver/gpio.h"
#include "driver/rmt_tx.h"
#include "esp_chip_info.h"
#include "esp_flash.h"
#include "esp_heap_caps.h"
#include "esp_psram.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include "soc/gpio_reg.h"
#include "soc/soc.h"

namespace {

// Every GPIO not taken by the module: 19/20 are native USB, 26-32 the SPI
// flash, 33-37 the octal PSRAM, 43/44 the console UART.
constexpr std::array<int, 30> free_pins{0,  1,  2,  3,  4,  5,  6,  7,  8,  9,
                                        10, 11, 12, 13, 14, 15, 16, 17, 18, 21,
                                        38, 39, 40, 41, 42, 45, 46, 47, 48, -1};

int read_with_pull(int pin, bool pull_up) {
    gpio_config_t config{};
    config.pin_bit_mask = 1ULL << pin;
    config.mode         = GPIO_MODE_INPUT;
    config.pull_up_en   = pull_up ? GPIO_PULLUP_ENABLE : GPIO_PULLUP_DISABLE;
    config.pull_down_en =
            pull_up ? GPIO_PULLDOWN_DISABLE : GPIO_PULLDOWN_ENABLE;
    gpio_config(&config);
    vTaskDelay(pdMS_TO_TICKS(2));
    return gpio_get_level(static_cast<gpio_num_t>(pin));
}

void scan_pins() {
    std::printf("PROBE pins: pin  pull-down  pull-up  verdict\n");
    for (const int pin : free_pins) {
        if (pin < 0) {
            continue;
        }
        const int low  = read_with_pull(pin, false);
        const int high = read_with_pull(pin, true);
        const char *verdict =
                (low == 0 && high == 1)   ? "floats"
                : (low == 1 && high == 1) ? "HELD HIGH by the board"
                : (low == 0 && high == 0) ? "HELD LOW by the board"
                                          : "INVERTS (odd)";
        std::printf("PROBE pin %2d  %d  %d  %s\n", pin, low, high, verdict);
        gpio_reset_pin(static_cast<gpio_num_t>(pin));
    }
}

void report_chip() {
    esp_chip_info_t chip{};
    esp_chip_info(&chip);
    uint32_t flash_size = 0;
    esp_flash_get_size(nullptr, &flash_size);
    uint32_t flash_id = 0;
    esp_flash_read_id(nullptr, &flash_id);
    std::printf("PROBE chip: cores %d, revision v%d.%d, flash %" PRIu32
                " MiB (JEDEC id %06" PRIx32 "), PSRAM %u MiB\n",
                chip.cores, chip.revision / 100, chip.revision % 100,
                flash_size >> 20, flash_id,
                static_cast<unsigned>(esp_psram_get_size() >> 20));
    // The ROM prints the same value as its "boot:0x.." (0x8: GPIO0 high,
    // SPI boot).
    std::printf("PROBE strap: GPIO_STRAP_REG 0x%08" PRIx32 "\n",
                REG_READ(GPIO_STRAP_REG));
    std::printf("PROBE heap: internal %u KiB free, PSRAM %u KiB free\n",
                static_cast<unsigned>(
                        heap_caps_get_free_size(MALLOC_CAP_INTERNAL) >> 10),
                static_cast<unsigned>(heap_caps_get_free_size(MALLOC_CAP_SPIRAM)
                                      >> 10));
}

void measure_psram() {
    constexpr size_t size = 1 << 20;
    auto *source =
            static_cast<uint8_t *>(heap_caps_malloc(size, MALLOC_CAP_SPIRAM));
    auto *target =
            static_cast<uint8_t *>(heap_caps_malloc(size, MALLOC_CAP_SPIRAM));
    if (source == nullptr || target == nullptr) {
        std::printf("PROBE psram: allocation FAILED\n");
        return;
    }
    for (size_t i = 0; i < size; ++i) {
        source[i] = static_cast<uint8_t>(i * 2654435761u >> 24);
    }
    const int64_t start = esp_timer_get_time();
    for (int round = 0; round < 8; ++round) {
        std::memcpy(target, source, size);
    }
    const int64_t elapsed = esp_timer_get_time() - start;
    const bool same       = std::memcmp(source, target, size) == 0;
    std::printf(
            "PROBE psram: memcpy 8 x 1 MiB in %lld us = %.1f MB/s, copy %s\n",
            static_cast<long long>(elapsed), 8.0 * size / elapsed,
            same ? "verified" : "CORRUPT");
    heap_caps_free(source);
    heap_caps_free(target);
}

void scan_wifi() {
    nvs_flash_init();
    esp_netif_init();
    esp_event_loop_create_default();
    wifi_init_config_t config = WIFI_INIT_CONFIG_DEFAULT();
    esp_wifi_init(&config);
    esp_wifi_set_mode(WIFI_MODE_STA);
    esp_wifi_start();
    if (esp_wifi_scan_start(nullptr, true) != ESP_OK) {
        std::printf("PROBE wifi: scan FAILED\n");
        return;
    }
    uint16_t count = 0;
    esp_wifi_scan_get_ap_num(&count);
    std::vector<wifi_ap_record_t> records(count);
    esp_wifi_scan_get_ap_records(&count, records.data());
    int best = -127;
    for (const auto &record : records) {
        best = record.rssi > best ? record.rssi : best;
    }
    std::printf("PROBE wifi: %u access points, strongest %d dBm\n", count,
                best);
    esp_wifi_stop();
    esp_wifi_deinit();
}

// One step of an LED sequence: a colour, in the WS2812's byte order, held
// for a time.
struct Step {
    const char *name;
    std::array<uint8_t, 3> grb;
    int milliseconds;
};

// The two candidate pins get sequences a watcher can tell apart: GPIO48
// red, green, blue (which also shows the colour order is right), GPIO38
// three white blinks.
constexpr std::array<Step, 4> gpio48_steps{{{"red", {0, 40, 0}, 3000},
                                            {"green", {40, 0, 0}, 3000},
                                            {"blue", {0, 0, 40}, 3000},
                                            {"off", {0, 0, 0}, 3000}}};
constexpr std::array<Step, 6> gpio38_steps{{{"white", {40, 40, 40}, 500},
                                            {"off", {0, 0, 0}, 500},
                                            {"white", {40, 40, 40}, 500},
                                            {"off", {0, 0, 0}, 500},
                                            {"white", {40, 40, 40}, 500},
                                            {"off", {0, 0, 0}, 3000}}};

// WS2812: 10 MHz ticks; a 0 is 0.4 us high and 0.85 us low, a 1 is 0.8 us
// high and 0.45 us low; the bytes go green, red, blue.
template <size_t count>
void show_ws2812(int pin, const std::array<Step, count> &steps) {
    rmt_tx_channel_config_t channel_config{};
    channel_config.gpio_num          = static_cast<gpio_num_t>(pin);
    channel_config.clk_src           = RMT_CLK_SRC_DEFAULT;
    channel_config.resolution_hz     = 10'000'000;
    channel_config.mem_block_symbols = 64;
    channel_config.trans_queue_depth = 4;
    rmt_channel_handle_t channel     = nullptr;
    rmt_new_tx_channel(&channel_config, &channel);

    rmt_bytes_encoder_config_t encoder_config{};
    encoder_config.bit0            = {4, 1, 9, 0};
    encoder_config.bit1            = {8, 1, 5, 0};
    encoder_config.flags.msb_first = 1;
    rmt_encoder_handle_t encoder   = nullptr;
    rmt_new_bytes_encoder(&encoder_config, &encoder);
    rmt_enable(channel);

    rmt_transmit_config_t transmit{};
    for (const auto &step : steps) {
        std::printf("PROBE ws2812: GPIO%d %s\n", pin, step.name);
        rmt_transmit(channel, encoder, step.grb.data(), step.grb.size(),
                     &transmit);
        rmt_tx_wait_all_done(channel, -1);
        vTaskDelay(pdMS_TO_TICKS(step.milliseconds));
    }
    rmt_disable(channel);
    rmt_del_channel(channel);
    rmt_del_encoder(encoder);
    gpio_reset_pin(static_cast<gpio_num_t>(pin));
}

} // namespace

extern "C" void app_main() {
    report_chip();
    scan_pins();
    measure_psram();
    scan_wifi();
    std::printf("PROBE ws2812: sequence starts\n");
    while (true) {
        show_ws2812(48, gpio48_steps);
        show_ws2812(38, gpio38_steps);
        std::printf("PROBE done; repeating the LED sequence\n");
    }
}
