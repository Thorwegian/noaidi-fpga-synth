idf_component_register(SRCS "main.c" "midi_in.c" "midi_parser.c" "spi_regs.c"
                       PRIV_REQUIRES spi_flash esp_driver_spi esp_driver_gpio esp_driver_uart
                       INCLUDE_DIRS "")
