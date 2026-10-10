// spi_regs.c — ESP32-C3 SPI transport for the spi_bus word protocol
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// fpga_spi_init() sets up the ESP-IDF SPI-master bus and device; the
// fpga_word_* helpers and fpga_swap() speak spi_bus.sv's protocol (16-bit
// word addresses, 32-bit data — docs/memory_map.md).

#include "spi_regs.h"
#include "driver/spi_master.h"
#include "esp_log.h"

static const char *TAG = "fpga_spi";

static spi_device_handle_t s_spi;

// ── Initialisation ──────────────────────────────────────────────────
void fpga_spi_init(int mosi_pin, int miso_pin, int sclk_pin, int cs_pin,
                   uint32_t freq_hz)
{
    spi_bus_config_t bus_cfg = {
        .mosi_io_num     = mosi_pin,
        .miso_io_num     = miso_pin,
        .sclk_io_num     = sclk_pin,
        .quadwp_io_num   = -1,
        .quadhd_io_num   = -1,
        .max_transfer_sz = 64,   // plenty for register bursts
    };

    spi_device_interface_config_t dev_cfg = {
        .mode          = 0,                  // CPOL=0, CPHA=0
        .clock_speed_hz = freq_hz,
        .spics_io_num  = cs_pin,
        .queue_size    = 1,
//        .flags         = SPI_DEVICE_HALFDUPLEX,
    };

    ESP_ERROR_CHECK(spi_bus_initialize(SPI2_HOST, &bus_cfg, SPI_DMA_DISABLED));
    ESP_ERROR_CHECK(spi_bus_add_device(SPI2_HOST, &dev_cfg, &s_spi));
    ESP_LOGI(TAG, "SPI init: MOSI=%d MISO=%d SCLK=%d CS=%d freq=%lu",
             mosi_pin, miso_pin, sclk_pin, cs_pin, freq_hz);
}

// ── Low-level: transmit N bytes in ONE CS-framed transaction ────────
// A single spi_device_transmit asserts CS, clocks all `length` bits, then
// deasserts CS — so CS stays LOW across every byte in `buf`.  This is the
// native burst mode: do NOT call this once per byte (that would raise CS
// between bytes and break the FPGA's command/data framing).
static void fpga_xfer_bytes(const uint8_t *tx, size_t nbytes)
{
    spi_transaction_t t = {
        .length    = nbytes * 8,
        .tx_buffer = tx,
        .rx_buffer = NULL,
    };
    // POLLING transmit, not the interrupt/queue path: engine_link is
    // the sole SPI owner, and these are tiny frequent frames. The
    // interrupt driver's per-transaction cost (bus-lock bg request,
    // esp_intr_enable, a semaphore wait) dominated and pinned
    // engine_link under a CC flood. Polling busy-waits the ~5 µs
    // of wire time instead — far less overhead per word burst.
    ESP_ERROR_CHECK(spi_device_polling_transmit(s_spi, &t));
}

// ── Low-level: full-duplex N bytes in ONE CS-framed transaction ─────
// Like fpga_xfer_bytes, but also captures MISO into `rx`.  `tx` and `rx`
// must each hold nbytes.  Used for reads.
static void fpga_xfer_bytes_duplex(const uint8_t *tx, uint8_t *rx, size_t nbytes)
{
    spi_transaction_t t = {
        .length    = nbytes * 8,
        .tx_buffer = tx,
        .rx_buffer = rx,
    };
    ESP_ERROR_CHECK(spi_device_transmit(s_spi, &t));
}

// ═══════════════════════════════════════════════════════════════════
// Word protocol (rtl/spi/spi_bus.sv — the docs/memory_map.md format)
//
//   byte 0      command: [7] R/W (1=read), [6] auto-increment
//   bytes 1..2  16-bit word address, MSB first
//   write:      + 4N data bytes (32-bit words, MSB first)
//   read:       + 2 dummy bytes (fetch turnaround) + 4N data bytes
//
// MISO byte 0 is always 0xA5 (the slave's ID: a free link check).
// ═══════════════════════════════════════════════════════════════════

#define BURST_MAX_WORDS 8   // per transaction, sized for the local frame buffer

void fpga_word_write_burst(uint16_t addr, const uint32_t *words, size_t n)
{
    uint8_t frame[3 + 4 * BURST_MAX_WORDS];
    if (n > BURST_MAX_WORDS) n = BURST_MAX_WORDS;
    frame[0] = 0x40;                    // write, auto-increment
    frame[1] = (uint8_t)(addr >> 8);
    frame[2] = (uint8_t)(addr & 0xFF);
    for (size_t i = 0; i < n; i++) {
        frame[3 + 4*i] = (uint8_t)(words[i] >> 24);
        frame[4 + 4*i] = (uint8_t)(words[i] >> 16);
        frame[5 + 4*i] = (uint8_t)(words[i] >> 8);
        frame[6 + 4*i] = (uint8_t)(words[i]);
    }
    fpga_xfer_bytes(frame, 3 + 4 * n);
}

void fpga_word_write(uint16_t addr, uint32_t value)
{
    fpga_word_write_burst(addr, &value, 1);
}

// Returns false if the ID byte is missing (link fault).
bool fpga_word_read_burst(uint16_t addr, uint32_t *words, size_t n)
{
    uint8_t tx[5 + 4 * BURST_MAX_WORDS] = {0};
    uint8_t rx[5 + 4 * BURST_MAX_WORDS] = {0};
    if (n > BURST_MAX_WORDS) n = BURST_MAX_WORDS;
    tx[0] = 0xC0;                       // read, auto-increment
    tx[1] = (uint8_t)(addr >> 8);
    tx[2] = (uint8_t)(addr & 0xFF);
    fpga_xfer_bytes_duplex(tx, rx, 5 + 4 * n);
    for (size_t i = 0; i < n; i++) {
        words[i] = ((uint32_t)rx[5 + 4*i] << 24)
                 | ((uint32_t)rx[6 + 4*i] << 16)
                 | ((uint32_t)rx[7 + 4*i] << 8)
                 |  (uint32_t)rx[8 + 4*i];
    }
    return rx[0] == 0xA5;
}

uint32_t fpga_word_read(uint16_t addr)
{
    uint32_t v = 0;
    fpga_word_read_burst(addr, &v, 1);
    return v;
}

// ── Page swap (ping-pong) ───────────────────────────────────────────
#include "esp_rom_sys.h"

void fpga_swap(void)
{
    fpga_word_write(0x0002, 0x00000001);   // CTRL: swap request
    // flip executes at time slot 512; one sample period is 10.42 us at
    // 96 kHz — wait two to be safely on the other side
    esp_rom_delay_us(21);
}
