idf_component_register(SRCS "main.c" "event_bus.c" "midi_in.c" "midi_log.c"
                       "midi_parser.c" "spi_regs.c" "engine_link.c"
                       "voice_alloc.c" "slider.c"
                       PRIV_REQUIRES spi_flash esp_driver_spi esp_driver_gpio esp_driver_uart esp_timer
                                     esp_adc nvs_flash esp_driver_usb_serial_jtag
                       INCLUDE_DIRS "")
