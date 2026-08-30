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
    ESP_ERROR_CHECK(spi_device_transmit(g_spi, &t));
}

// ── Single-register write ──────────────────────────────────────────
// Command byte + data byte go out in ONE CS-framed transaction (16 bits).
void fpga_reg_write(uint8_t addr, uint8_t data)
{
    uint8_t frame[2] = { (0 << 7) | (addr & 0x7F), data };
    fpga_xfer_bytes(frame, 2);
}

// ── Raw link probe (diagnostic) ────────────────────────────────────
// Sends 5 bytes and prints every MISO byte returned.  This is NOT a
// loopback: the FPGA decodes byte 0 as a command like any other
// transaction.  What matters is the first byte.
//
//   MISO[0] == 0xA5  → the physical MISO path works.  The slave returns
//                      its ID byte here on every transaction, so this is
//                      a free link check.
//   MISO[0] == 0x00  → MISO is dead (wiring, pin constraint, or the
//                      slave is not being clocked).  Nothing downstream
//                      is worth debugging until this reads 0xA5.
//   MISO[0] == 0xFF  → line floating / not driven.
//
// Bytes 1..4 are register contents: 0xAA is a READ command for address
// 0x2A & 0x0F = 10, so they show mem[10..13].
void fpga_raw_link_probe(void)
{
    uint8_t tx[5] = {0xAA, 0x55, 0x11, 0x22, 0x33};
    uint8_t rx[5] = {0xEE, 0xEE, 0xEE, 0xEE, 0xEE};
    fpga_xfer_bytes_duplex(tx, rx, 5);
    printf("MISO: %02X %02X %02X %02X %02X   (byte 0 must be A5)\n",
           rx[0], rx[1], rx[2], rx[3], rx[4]);
}

// ── Single-register read ───────────────────────────────────────────
// Read protocol (matches rtl/spi/spi_slave_regs.sv): command byte
// (R/W=1, addr) + data bytes, all in ONE CS-framed transaction.  The
// command byte itself is the turnaround, so mem[addr] appears on MISO at
// byte index 1: the slave latches addr on the 8th rising edge of the
// command byte and loads the combinational mem[addr] onto MISO at the
// falling edge immediately after.  MISO byte 0 is the slave's ID (0xA5).
uint8_t fpga_reg_read(uint8_t addr)
{
    uint8_t frame[3];   // cmd + 1 dummy + 1 data = 3 bytes
    uint8_t rxb[3];

    frame[0] = (1 << 7) | (addr & 0x7F);   // command: read
    frame[1] = 0x00;                       // dummy
    frame[2] = 0x00;                       // data (MISO carries mem[addr])

    fpga_xfer_bytes_duplex(frame, rxb, 3);
    return rxb[1];   // data is at byte index 1 (after the command byte)
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
// Read `len` bytes starting at `addr` (auto-increment on the FPGA side).
// One CS-framed transaction: cmd + 1 dummy + len data bytes.  Data starts
// at rxb index 1.
void fpga_reg_read_burst(uint8_t addr, uint8_t *buf, size_t len)
{
    // cmd + 1 dummy + up to 32 data bytes
    uint8_t tx[34];
    uint8_t rx[34];

    tx[0] = (1 << 7) | (addr & 0x7F);
    tx[1] = 0x00;   // dummy
    for (size_t i = 0; i < len && i < 32; i++)
        tx[2 + i] = 0x00;

    fpga_xfer_bytes_duplex(tx, rx, 2 + (len < 32 ? len : 32));

    for (size_t i = 0; i < len && i < 32; i++)
        buf[i] = rx[1 + i];   // data starts at byte index 1 (after 1 dummy)
}

// ═══════════════════════════════════════════════════════════════════
// Word protocol (rtl/spi/spi_bus.sv — the docs/memory_map.md format)
//
//   byte 0      command: [7] R/W (1=read), [6] auto-increment
//   bytes 1..2  16-bit word address, MSB first
//   write:      + 4N data bytes (32-bit words, MSB first)
//   read:       + 2 dummy bytes (fetch turnaround) + 4N data bytes
//
// MISO byte 0 is always 0xA5. These functions coexist with the byte
// protocol above; which one is live depends on the loaded bitstream
// (spi_slave_regs = bytes, spi_bus = words).
// ═══════════════════════════════════════════════════════════════════

#define WORDS_MAX 8   // per transaction, sized for the local frame buffer

void fpga_word_write_burst(uint16_t addr, const uint32_t *words, size_t n)
{
    uint8_t frame[3 + 4 * WORDS_MAX];
    if (n > WORDS_MAX) n = WORDS_MAX;
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
    uint8_t tx[5 + 4 * WORDS_MAX] = {0};
    uint8_t rx[5 + 4 * WORDS_MAX] = {0};
    if (n > WORDS_MAX) n = WORDS_MAX;
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

// ── Bank swap (ping-pong) ───────────────────────────────────────────
#include "esp_rom_sys.h"

void fpga_swap(void)
{
    fpga_word_write(0x0002, 0x00000001);   // CTRL: swap request
    // flip executes at drum slot 512; one sample period is 10.42 us at
    // 96 kHz — wait two to be safely on the other side
    esp_rom_delay_us(21);
}
