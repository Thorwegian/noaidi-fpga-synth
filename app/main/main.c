// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include <stdio.h>
#include <inttypes.h>
#include "sdkconfig.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_chip_info.h"
#include "esp_flash.h"
#include "esp_system.h"
#include "esp_app_desc.h"

#include "spi_link.h"
#include "midi_in.h"
#include "midi_log.h"
#include "midi_out.h"
#include "event_bus.h"
#include "engine_link.h"
#include "voice_alloc.h"
#include "console.h"
#include "cli.h"
#include "nvs_flash.h"
#include "ble_midi.h"
#include "stress_test.h"
#include "storage.h"

void app_main(void) {
    // The serial console first: from here on stdout and ESP_LOG print
    // through it (console.h).
    console_init();

    // Boot banner: WHICH build is running (esp_app_desc is regenerated
    // every build — version is git-describe, date/time is the compile).
    // Exists because a hash-verified flash can leave the old app
    // running (a USB-JTAG hard-reset quirk): trust this line, not
    // esptool's exit code.
    const esp_app_desc_t *ad = esp_app_get_description();
    printf("=== noaidi fw %s (built %s %s) ===\n", ad->version, ad->date,
           ad->time);

    /* Print chip information */
    esp_chip_info_t chip_info;
    uint32_t flash_size;
    esp_chip_info(&chip_info);
    printf("This is %s chip with %d CPU core(s), %s%s%s%s, ", CONFIG_IDF_TARGET,
           chip_info.cores,
           (chip_info.features & CHIP_FEATURE_WIFI_BGN) ? "WiFi/" : "",
           (chip_info.features & CHIP_FEATURE_BT) ? "BT" : "",
           (chip_info.features & CHIP_FEATURE_BLE) ? "BLE" : "",
           (chip_info.features & CHIP_FEATURE_IEEE802154)
                   ? ", 802.15.4 (Zigbee/Thread)"
                   : "");

    unsigned major_rev = chip_info.revision / 100;
    unsigned minor_rev = chip_info.revision % 100;
    printf("silicon revision v%d.%d, ", major_rev, minor_rev);
    if (esp_flash_get_size(NULL, &flash_size) != ESP_OK) {
        printf("Get flash size failed");
        return;
    }

    printf("%" PRIu32 "MB %s flash\n", flash_size / (uint32_t) (1024 * 1024),
           (chip_info.features & CHIP_FEATURE_EMB_FLASH) ? "embedded"
                                                         : "external");

    printf("Minimum free heap size: %" PRIu32 " bytes\n",
           esp_get_minimum_free_heap_size());

    // Preset storage: mount before anything loads a preset.
    storage_init();

    // Event bus first, then the consumers that subscribe to it; the outputs
    // (parameter feedback, #279) before anything can ask them to send.
    event_bus_init();
    midi_out_init();
    midi_log_init();

    // UART1 RX must init before SPI: UART1's default TX pin (GPIO7) is
    // the SPI CS pin, so the SPI init must run last and re-claim it.
    midi_in_init(0);

    // Panel MIDI: UART0 on GPIO2, from the dev host via USB-MIDI.
    // Open Stage Control exclusively — test scripts stay on BLE/DIN.
    midi_panel_init(2);

    // 10 MHz: the link is measured clean to 40; at 1 MHz a note-on's
    // 32 dwords (~130 us each) would blow the engine's 1 ms tick.
    spi_link_init(6, 5, 4, 7, 10000000); // MOSI, MISO, SCLK, CS

    // The link in nines, checked as tb_spi_bus.sv checks the slave, so that
    // firmware and RTL agree on the same evidence.
    spi_link_boot_check();

    // ── The synth proper ────────────────────────────────────────────
    // engine_link takes sole ownership of the SPI link from here on
    // (it loads the CSP's control program), then voice_alloc turns MIDI into
    // voices of 8 partials.
    printf("=== voice concept: 32 voices x 8 partials, MIDI omni ===\n");
    engine_link_init();
    voice_alloc_init();
    midi_in_start(); // subscribers are registered: start publishing
    // NVS holds the BLE bonds. A full or version-mismatched partition is
    // erased and reinitialized: it only ever holds settings.
    esp_err_t nvs = nvs_flash_init();
    if (nvs == ESP_ERR_NVS_NO_FREE_PAGES
        || nvs == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        nvs = nvs_flash_init();
    }
    ESP_ERROR_CHECK(nvs);
    ble_midi_init(); // MIDI over BLE: advertise "Noaidi" (standard MIDI service)
#if CONFIG_NOAIDI_STRESS_TEST
    stress_test_start(); // synthetic MIDI flood; off by default
#endif
    // NOTE: boot-capture tooling waits for the "play the keyboard"
    // marker - keep the prefix if this line ever changes.
    printf("play the keyboard\n");
    cli_init(); // console commands and status bar
}
