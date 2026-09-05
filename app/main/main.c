#include <stdio.h>
#include <inttypes.h>
#include "sdkconfig.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_chip_info.h"
#include "esp_flash.h"
#include "esp_system.h"

#include "spi_regs.h"
#include "midi_in.h"
#include "midi_log.h"
#include "event_bus.h"
#include "engine_link.h"
#include "voice_alloc.h"
#include "slider.h"
#include "ble_midi.h"

void app_main(void)
{
    /* Print chip information */
    esp_chip_info_t chip_info;
    uint32_t flash_size;
    esp_chip_info(&chip_info);
    printf("This is %s chip with %d CPU core(s), %s%s%s%s, ",
           CONFIG_IDF_TARGET,
           chip_info.cores,
           (chip_info.features & CHIP_FEATURE_WIFI_BGN) ? "WiFi/" : "",
           (chip_info.features & CHIP_FEATURE_BT) ? "BT" : "",
           (chip_info.features & CHIP_FEATURE_BLE) ? "BLE" : "",
           (chip_info.features & CHIP_FEATURE_IEEE802154) ? ", 802.15.4 (Zigbee/Thread)" : "");

    unsigned major_rev = chip_info.revision / 100;
    unsigned minor_rev = chip_info.revision % 100;
    printf("silicon revision v%d.%d, ", major_rev, minor_rev);
    if(esp_flash_get_size(NULL, &flash_size) != ESP_OK) {
        printf("Get flash size failed");
        return;
    }

    printf("%" PRIu32 "MB %s flash\n", flash_size / (uint32_t)(1024 * 1024),
           (chip_info.features & CHIP_FEATURE_EMB_FLASH) ? "embedded" : "external");

    printf("Minimum free heap size: %" PRIu32 " bytes\n", esp_get_minimum_free_heap_size());

    // Event bus first, then the consumers that subscribe to it.
    event_bus_init();
    midi_log_init();

    // UART1 RX must init before SPI: UART1's default TX pin (GPIO7) is
    // the SPI CS pin, so the SPI init must run last and re-claim it.
    midi_in_init(0);

    // 10 MHz: the link is measured clean to 40; at 1 MHz a note-on's
    // 32 words (~60 us each) would blow the engine's 1 ms tick.
    fpga_spi_init(6, 5, 4, 7, 10000000); // MOSI, MISO, SCLK, CS

    // Word-protocol self-test (spi_bus.sv / docs/memory_map.md format).
    // Mirrors tb_spi_bus.sv's cases so firmware and RTL agree on the
    // same evidence.
    int fails = 0;

    printf("=== 1. single word write/read ===\n");
    fpga_word_write(0x0005, 0xDEADBEEF);
    uint32_t v = fpga_word_read(0x0005);
    printf("word[0x0005] = %08lX %s\n", (unsigned long)v,
           v == 0xDEADBEEF ? "OK" : "FAIL");
    fails += (v != 0xDEADBEEF);

    printf("=== 2. burst auto-increment (LFO region) ===\n");
    uint32_t wq[4] = {0x11111111, 0x22222222, 0x33333333, 0x44444444};
    uint32_t rq[4] = {0};
    fpga_word_write_burst(0x0100, wq, 4);
    bool id_ok = fpga_word_read_burst(0x0100, rq, 4);
    for (int i = 0; i < 4; i++) {
        printf("word[0x%04X] = %08lX %s\n", 0x0100 + i, (unsigned long)rq[i],
               rq[i] == wq[i] ? "OK" : "FAIL");
        fails += (rq[i] != wq[i]);
    }
    printf("ID byte on read frame: %s\n", id_ok ? "OK (A5)" : "FAIL");
    fails += !id_ok;

    printf("=== 3. out-of-window: dropped and zero, no alias ===\n");
    fpga_word_write(0x0805, 0xBAD0BAD0);      // would alias 0x0005 if broken
    uint32_t z = fpga_word_read(0x0805);
    uint32_t keep = fpga_word_read(0x0005);
    printf("word[0x0805] = %08lX %s, word[0x0005] = %08lX %s\n",
           (unsigned long)z, z == 0 ? "OK" : "FAIL",
           (unsigned long)keep, keep == 0xDEADBEEF ? "OK" : "FAIL");
    fails += (z != 0) + (keep != 0xDEADBEEF);

    printf("=== RESULT: %s (%d fails) ===\n", fails ? "FAIL" : "ALL OK", fails);

    // ── The synth proper ────────────────────────────────────────────
    // engine_link takes sole ownership of the SPI link from here on
    // (mutes both banks at init — the boot organ goes silent), then
    // voice_alloc turns MIDI into voices of 8 elements.
    printf("=== voice concept: 32 voices x 8 elements, MIDI omni ===\n");
    engine_link_init();
    voice_alloc_init();
    slider_init();   // panel slider -> CC71 (resonance); 'c' = calibrate
    ble_midi_init(); // MIDI over BLE: advertise "Noaidi" (standard MIDI service)
    printf("play the keyboard — gate-by-gain, clicks expected\n");
}
