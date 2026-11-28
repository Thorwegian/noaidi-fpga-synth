# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2

# stress_test.c is the flood that CONFIG_NOAIDI_STRESS_TEST's call in main.c
# starts, so it is built only when that call is.
set(main_srcs
    "main.c" "event_bus.c" "midi_in.c" "midi_log.c"
    "midi_parser.c" "spi_link.cpp" "engine_link.cpp" "engine_image.cpp" "engine_selftest.cpp" "sound_engine.cpp"
    "voice_alloc.cpp" "cc_map.cpp" "midi_out.cpp" "midi_sysex.cpp" "ble_midi.c" "console.c" "cli.cpp" "cli_banks.cpp" "cli_system.c" "cli_csp.cpp"
    "usb_midi.cpp" "storage.c" "preset_units.cpp" "preset.cpp" "preset_file.cpp" "safe_file.cpp" "banks.cpp"
    "csp/csp.cpp" "csp/program_builder.cpp" "csp/envelope.cpp" "csp/dsp_graph.cpp" "csp/selftest.cpp"
    "../lib/tomlc17/src/tomlc17.c")
if(CONFIG_NOAIDI_STRESS_TEST)
    list(APPEND main_srcs "stress_test.c")
endif()

idf_component_register(SRCS ${main_srcs}
                       PRIV_REQUIRES spi_flash esp_app_format esp_driver_spi esp_driver_gpio esp_driver_uart esp_timer
                                     nvs_flash bt esp_ringbuf esp_psram esp_tinyusb
                                     fatfs wear_levelling vfs
                       INCLUDE_DIRS ""
                       PRIV_INCLUDE_DIRS "../lib/tomlc17/src")

target_compile_definitions(${COMPONENT_LIB} PRIVATE NOAIDI_BUILD="${NOAIDI_BUILD}")

# The format check runs ahead of this component's compilation, so every path
# that builds the firmware runs it: `make fw`'s prerequisite is one door in,
# and tools/esp_idf.sh idf.py build — the lab box's path — is another, with no
# Makefile in it (#613).
add_custom_target(format_check ALL
    COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/../../tools/format_check.sh
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../..
    COMMENT "Checking that the sources are formatted"
    VERBATIM)
add_dependencies(${COMPONENT_LIB} format_check)

# tomlc17 prints a uint32_t with %x, which is a format mismatch on this
# target (uint32_t is unsigned long); it only affects an error message.
set_source_files_properties("../lib/tomlc17/src/tomlc17.c" PROPERTIES COMPILE_OPTIONS "-Wno-format")
