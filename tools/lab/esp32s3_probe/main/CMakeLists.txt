# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2

idf_component_register(SRCS "probe_main.cpp"
                       PRIV_REQUIRES spi_flash esp_psram esp_driver_gpio esp_driver_rmt esp_wifi nvs_flash esp_timer
                       INCLUDE_DIRS "")
