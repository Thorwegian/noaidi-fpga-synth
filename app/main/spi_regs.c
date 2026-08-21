// spi_regs.c — ESP32-C3 driver for spi_slave_regs FPGA peripheral
//
// Uses ESP-IDF SPI master API.  For Arduino-ESP32, the hardware
// SPI calls would differ slightly but the protocol logic is identical.

#include "spi_regs.h"
#include "driver/spi_master.h"
#include "esp_log.h"

#include <stdio.h>

static const char *TAG = "fpga_spi";

static spi_device_handle_t g_spi;

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
    ESP_ERROR_CHECK(spi_bus_add_device(SPI2_HOST, &dev_cfg, &g_spi));
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
    ESP_ERROR_CHECK(spi_device_transmit(g_spi, &t));
}

// ── Single-register write ──────────────────────────────────────────
// Command byte + data byte go out in ONE CS-framed transaction (16 bits).
void fpga_reg_write(uint8_t addr, uint8_t data)
{
    uint8_t frame[2] = { (0 << 7) | (addr & 0x7F), data };
    fpga_xfer_bytes(frame, 2);
}

// ── Single-register read ───────────────────────────────────────────
uint8_t fpga_reg_read(uint8_t addr)
{
    uint8_t cmd = (1 << 7) | (addr & 0x7F);
    // TODO Step 3: real read-back over MISO.  For now the register bank
    // does not yet return data, so this is a stub.
    fpga_xfer_bytes(&cmd, 1);
    return 0;
}

// ── Burst write ────────────────────────────────────────────────────
// Command byte + N data bytes in ONE CS-framed transaction.
void fpga_reg_write_burst(uint8_t addr, const uint8_t *data, size_t len)
{
    // Small local buffer for the command + data; registers use short bursts.
    uint8_t frame[33];   // 1 cmd + up to 32 data bytes
    frame[0] = (0 << 7) | (addr & 0x7F);
    for (size_t i = 0; i < len && i < 32; i++)
        frame[1 + i] = data[i];
    fpga_xfer_bytes(frame, 1 + (len < 32 ? len : 32));
}

// ── Burst read ─────────────────────────────────────────────────────
void fpga_reg_read_burst(uint8_t addr, uint8_t *buf, size_t len)
{
    // TODO Step 3: real burst read-back over MISO.
    uint8_t cmd = (1 << 7) | (addr & 0x7F);
    fpga_xfer_bytes(&cmd, 1);
    for (size_t i = 0; i < len; i++)
        buf[i] = 0;
}
