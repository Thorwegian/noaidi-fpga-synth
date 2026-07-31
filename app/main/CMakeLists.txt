idf_component_register(SRCS "main.c" "spi_regs.c"
                       PRIV_REQUIRES spi_flash esp_driver_spi
                       INCLUDE_DIRS "")
