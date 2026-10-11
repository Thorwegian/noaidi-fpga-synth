# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2

idf_component_register(SRCS "main.c" "event_bus.c" "midi_in.c" "midi_log.c"
                       "midi_parser.c" "spi_regs.c" "engine_link.c"
                       "voice_alloc.c" "ble_midi.c" "patch.c" "console.c" "cli.c"
                       "stress_test.c" "storage.c" "patch_units.c" "patch_file.c"
                       "../lib/tomlc17/src/tomlc17.c"
                       PRIV_REQUIRES spi_flash esp_app_format esp_driver_spi esp_driver_gpio esp_driver_uart esp_timer
                                     nvs_flash esp_driver_usb_serial_jtag bt esp_ringbuf
                                     fatfs wear_levelling vfs
                       INCLUDE_DIRS ""
                       PRIV_INCLUDE_DIRS "../lib/tomlc17/src")

# tomlc17 prints a uint32_t with %x, which is a format mismatch on this
# target (uint32_t is unsigned long); it only affects an error message.
set_source_files_properties("../lib/tomlc17/src/tomlc17.c" PROPERTIES COMPILE_OPTIONS "-Wno-format")
