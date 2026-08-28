idf_component_register(SRCS "main.c" "event_bus.c" "midi_in.c" "midi_log.c"
                       "midi_parser.c" "spi_regs.c"
                       PRIV_REQUIRES spi_flash esp_driver_spi esp_driver_gpio esp_driver_uart esp_timer
                       INCLUDE_DIRS "")
