// spi_regs.c — ESP32-C3 driver for spi_slave_regs FPGA peripheral
//
// Uses ESP-IDF SPI master API.  For Arduino-ESP32, the hardware
// SPI calls would differ slightly but the protocol logic is identical.

#include "spi_regs.h"
#include "driver/spi_master.h"
#include "esp_log.h"

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

// ── Low-level: exchange a single byte ───────────────────────────────
static uint8_t fpga_xfer_byte(uint8_t tx)
{
    spi_transaction_t t = {
        .length    = 8,
        .tx_buffer = &tx,
        .rx_buffer = NULL,
    };
    uint8_t rx;
    t.rx_buffer = &rx;
    ESP_ERROR_CHECK(spi_device_transmit(g_spi, &t));
    return rx;
}

// ── Single-register write ──────────────────────────────────────────
void fpga_reg_write(uint8_t addr, uint8_t data)
{
    uint8_t cmd = (0 << 7) | (addr & 0x7F);
    fpga_xfer_byte(cmd);      // send command
    fpga_xfer_byte(data);     // send data
}

// ── Single-register read ───────────────────────────────────────────
uint8_t fpga_reg_read(uint8_t addr)
{
    uint8_t cmd = (1 << 7) | (addr & 0x7F);
    fpga_xfer_byte(cmd);      // send command, receive pre-XFER byte (ignore)
    fpga_xfer_byte(0x00);     // send dummy, receive status byte (ignore)
    return fpga_xfer_byte(0x00);  // send dummy, receive register data
}

// ── Burst write ────────────────────────────────────────────────────
void fpga_reg_write_burst(uint8_t addr, const uint8_t *data, size_t len)
{
    uint8_t cmd = (0 << 7) | (addr & 0x7F);
    fpga_xfer_byte(cmd);
    for (size_t i = 0; i < len; i++)
        fpga_xfer_byte(data[i]);
}

// ── Burst read ─────────────────────────────────────────────────────
void fpga_reg_read_burst(uint8_t addr, uint8_t *buf, size_t len)
{
    uint8_t cmd = (1 << 7) | (addr & 0x7F);
    fpga_xfer_byte(cmd);          // pre-XFER byte (discard)
    fpga_xfer_byte(0x00);         // status byte (discard)
    for (size_t i = 0; i < len; i++)
        buf[i] = fpga_xfer_byte(0x00);
}
