// spi_link.h — the SPI wire in nines, as C sees it (the C++ API is spi_link.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Bring the ESP-IDF SPI master up on these pins at this clock.
void spi_link_init(int mosi_pin, int miso_pin, int sclk_pin, int cs_pin, uint32_t frequency_hz);

// Check the link as tb_spi_bus.sv checks the slave — the ID nonet, a
// scratch dword written and read back whole, a burst, a status dword ignoring
// a write, an address outside every window dropped and read as zero — and
// print each. Returns the number of checks that failed.
int spi_link_boot_check(void);

#ifdef __cplusplus
}
#endif
