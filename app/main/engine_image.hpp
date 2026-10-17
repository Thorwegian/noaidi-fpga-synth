// engine_image.hpp — what the FPGA's registers and sinks hold, and what is yet to be sent
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The engine link's bookkeeping, without the RTOS and the SPI driver, so that
// the host tests and the system bench (rtl/tb/synth) run the code that runs on
// the board. A write of the value already there is dropped, what changed goes
// out in bursts of consecutive addresses, and one swap commits a tick's.

#pragma once

#include <array>
#include <bitset>
#include <cstdint>

#include "fpga_map.hpp"

// Where the words go: the SPI link, or a simulated one.
class EnginePort {
public:
    virtual ~EnginePort() = default;
    // Words to consecutive queue addresses, the first at `address`.
    virtual void queue_burst(uint16_t address, const uint32_t *words,
                             int count) = 0;
    // A word to a system register.
    virtual void write_register(uint16_t address, uint32_t value) = 0;
};

class EngineImage {
public:
    // Queue a write. A write of the value the FPGA already holds is dropped,
    // unless `force`: the CSP changes some registers itself (the levels, the
    // stages), and an image of them is only as good as the last write.
    // False if the address is out of range.
    bool set(int address, int32_t raw, bool force = false);

    bool pending() const {
        return pending_.any();
    }

    // What the FPGA should hold at `address`, if a write of it has been
    // sent and none is waiting: false otherwise (never written, or pending).
    bool known(int address, int32_t *raw) const;

    // Queue every known word again, so that the FPGA's copy is rebuilt
    // from the image: for a chip whose registers are in doubt.
    void resend_all();

    // Send at most `limit` pending words and commit them with a swap, the
    // CTRL word carrying `ctrl_bits` (hold, test tone). How many it sent.
    int send(EnginePort &port, int limit, uint32_t ctrl_bits);

private:
    static constexpr int words = fpga_map::address_count;
    std::array<int32_t, words> value_{};
    std::bitset<words> known_;   // the FPGA holds value_
    std::bitset<words> pending_; // value_ still to send
};
