// spi_link.cpp — the SPI wire in nines, over the ESP-IDF SPI master
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "spi_link.hpp"

#include <array>
#include <cstdio>

#include "driver/spi_master.h"
#include "esp_log.h"

namespace spi_link {

namespace {

constexpr const char *tag = "spi_link";

constexpr int command_nonets    = 1;
constexpr int address_nonets    = address_bits / nonet_bits;
constexpr int turnaround_nonets = nonets_per_dword;
constexpr int frame_max_nonets  = command_nonets + address_nonets
                                 + turnaround_nonets
                                 + nonets_per_dword * burst_max;
constexpr size_t frame_max_bytes = (frame_max_nonets * nonet_bits + 7) / 8;

constexpr uint32_t command_read           = uint32_t{1} << (nonet_bits - 1);
constexpr uint32_t command_auto_increment = uint32_t{1} << (nonet_bits - 2);

spi_device_handle_t device = nullptr;
int cs_pin_in_use          = -1;

void add_device(int cs_pin, uint32_t frequency_hz) {
    spi_device_interface_config_t interface = {};
    interface.mode                          = 0; // CPOL 0, CPHA 0
    interface.clock_speed_hz                = static_cast<int>(frequency_hz);
    interface.spics_io_num                  = cs_pin;
    interface.queue_size                    = 1;
    ESP_ERROR_CHECK(spi_bus_add_device(SPI2_HOST, &interface, &device));
    cs_pin_in_use = cs_pin;
}

// Bits appended MSB first into a byte buffer: the frame as the slave
// shifts it in, nine bits a nonet and nothing between.
class BitPacker {
public:
    explicit BitPacker(uint8_t *buffer) : buffer_(buffer) {}

    void append(uint64_t value, int bits) {
        for (int bit = bits - 1; bit >= 0; --bit) {
            if ((value >> bit) & 1) {
                buffer_[length_ / 8] |=
                        static_cast<uint8_t>(0x80 >> (length_ % 8));
            }
            ++length_;
        }
    }

    int length_bits() const {
        return length_;
    }

private:
    uint8_t *buffer_;
    int length_ = 0;
};

// Bits taken MSB first from a byte buffer: MISO as the master received it.
class BitReader {
public:
    explicit BitReader(const uint8_t *buffer) : buffer_(buffer) {}

    uint64_t take(int bits) {
        uint64_t value = 0;
        for (int bit = 0; bit < bits; ++bit) {
            value = (value << 1)
                    | ((buffer_[position_ / 8] >> (7 - position_ % 8)) & 1);
            ++position_;
        }
        return value;
    }

    void skip(int bits) {
        position_ += bits;
    }

private:
    const uint8_t *buffer_;
    int position_ = 0;
};

// One CS-framed transaction of `length_bits` bits, polling: the engine link
// is the sole SPI owner and these are tiny, frequent frames, for which the
// interrupt driver's per-transaction cost dominated.
void transfer(const uint8_t *tx, uint8_t *rx, int length_bits) {
    spi_transaction_t transaction = {};
    transaction.length            = static_cast<size_t>(length_bits);
    transaction.tx_buffer         = tx;
    transaction.rx_buffer         = rx;
    if (rx != nullptr) {
        transaction.rxlength = static_cast<size_t>(length_bits);
    }
    ESP_ERROR_CHECK(spi_device_polling_transmit(device, &transaction));
}

void header(BitPacker &packer, uint32_t command, uint32_t address) {
    packer.append(command, nonet_bits);
    packer.append(address, address_bits);
}

} // namespace

void init(int mosi_pin, int miso_pin, int sclk_pin, int cs_pin,
          uint32_t frequency_hz) {
    spi_bus_config_t bus = {};
    bus.mosi_io_num      = mosi_pin;
    bus.miso_io_num      = miso_pin;
    bus.sclk_io_num      = sclk_pin;
    bus.quadwp_io_num    = -1;
    bus.quadhd_io_num    = -1;
    bus.max_transfer_sz  = static_cast<int>(frame_max_bytes);

    ESP_ERROR_CHECK(spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_DISABLED));
    add_device(cs_pin, frequency_hz);
    ESP_LOGI(tag, "SPI in nines: MOSI %d MISO %d SCLK %d CS %d at %lu Hz",
             mosi_pin, miso_pin, sclk_pin, cs_pin,
             static_cast<unsigned long>(frequency_hz));
}

uint32_t set_frequency(uint32_t frequency_hz) {
    if (device != nullptr) {
        ESP_ERROR_CHECK(spi_bus_remove_device(device));
        device = nullptr;
    }
    add_device(cs_pin_in_use, frequency_hz);
    int actual_hz = 0;
    ESP_ERROR_CHECK(spi_device_get_actual_freq(device, &actual_hz));
    ESP_LOGI(tag, "SPI clock %lu Hz (asked %lu)",
             static_cast<unsigned long>(actual_hz) * 1000UL,
             static_cast<unsigned long>(frequency_hz));
    return static_cast<uint32_t>(actual_hz) * 1000U;
}

namespace {

void write_frame(uint32_t address, const dword_t *dwords, size_t count,
                 bool auto_increment) {
    if (count > static_cast<size_t>(burst_max)) {
        count = static_cast<size_t>(burst_max);
    }
    std::array<uint8_t, frame_max_bytes> frame{};
    BitPacker packer(frame.data());
    header(packer, auto_increment ? command_auto_increment : 0, address);
    for (size_t index = 0; index < count; ++index) {
        packer.append(dwords[index] & dword_mask, dword_bits);
    }
    transfer(frame.data(), nullptr, packer.length_bits());
}

} // namespace

void write(uint32_t address, const dword_t *dwords, size_t count) {
    write_frame(address, dwords, count, true);
}

void write_one(uint32_t address, dword_t dword) {
    write_frame(address, &dword, 1, true);
}

void write_repeated(uint32_t address, const dword_t *dwords, size_t count) {
    write_frame(address, dwords, count, false);
}

namespace {

bool read_frame(uint32_t address, dword_t *dwords, size_t count,
                bool auto_increment) {
    if (count > static_cast<size_t>(burst_max)) {
        count = static_cast<size_t>(burst_max);
    }
    std::array<uint8_t, frame_max_bytes> tx{};
    std::array<uint8_t, frame_max_bytes> rx{};
    BitPacker packer(tx.data());
    header(packer, command_read | (auto_increment ? command_auto_increment : 0),
           address);
    packer.append(0, nonet_bits * turnaround_nonets);
    packer.append(0, dword_bits * static_cast<int>(count));
    transfer(tx.data(), rx.data(), packer.length_bits());

    BitReader reader(rx.data());
    const uint32_t id = static_cast<uint32_t>(reader.take(nonet_bits));
    reader.skip(nonet_bits * (address_nonets + turnaround_nonets));
    for (size_t index = 0; index < count; ++index) {
        dwords[index] = reader.take(dword_bits);
    }
    return id == id_nonet;
}

} // namespace

bool read(uint32_t address, dword_t *dwords, size_t count) {
    return read_frame(address, dwords, count, true);
}

bool read_repeated(uint32_t address, dword_t *dwords, size_t count) {
    return read_frame(address, dwords, count, false);
}

dword_t read_one(uint32_t address) {
    dword_t dword = 0;
    read_frame(address, &dword, 1, true);
    return dword;
}

} // namespace spi_link

extern "C" void spi_link_init(int mosi_pin, int miso_pin, int sclk_pin,
                              int cs_pin, uint32_t frequency_hz) {
    spi_link::init(mosi_pin, miso_pin, sclk_pin, cs_pin, frequency_hz);
}

extern "C" int spi_link_boot_check(void) {
    using spi_link::dword_t;
    int fails  = 0;
    auto check = [&fails](const char *what, bool ok) {
        std::printf("%s %s\n", what, ok ? "OK" : "FAIL");
        fails += !ok;
    };

    std::printf("=== the link in nines (rtl/spi/spi_bus.sv) ===\n");
    constexpr uint32_t scratch =
            0x00003; // scratch is 0x3-0x6; 0x7 is the write trap (#238)
    constexpr dword_t whole = 0xDEADBEEF5ull; // all 36 bits
    spi_link::write_one(scratch, whole);
    check("1. a scratch dword written and read back whole",
          spi_link::read_one(scratch) == whole);

    std::array<dword_t, 3> burst{0x111111111ull, 0x222222222ull,
                                 0x333333333ull};
    std::array<dword_t, 3> back{};
    spi_link::write(scratch, burst.data(), burst.size());
    const bool id_ok = spi_link::read(scratch, back.data(), back.size());
    check("2. a burst of three dwords, auto-increment", back == burst);
    check("   the ID nonet on the read frame", id_ok);

    spi_link::write_one(0x00008, spi_link::dword_mask);
    check("3. a status dword ignores a write",
          spi_link::read_one(0x00008) != spi_link::dword_mask);

    spi_link::write_one(0x00803, 0xBAD0BAD03ull); // aliases 0x003 if broken
    check("4. an address outside every window reads zero",
          spi_link::read_one(0x00803) == 0);
    check("   and the scratch dword is unharmed",
          spi_link::read_one(scratch) == burst[0]);

    std::printf("=== RESULT: %s (%d fails) ===\n", fails ? "FAIL" : "ALL OK",
                fails);
    return fails;
}
