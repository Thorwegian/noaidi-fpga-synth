// engine_image.cpp — the register image behind the engine link
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "engine_image.hpp"

namespace {

constexpr int burst_dwords = 8; // the link's dwords per transaction

} // namespace

bool EngineImage::set(int address, int32_t raw, bool force) {
    if (address < 0 || address >= words) {
        return false;
    }
    raw &= static_cast<int32_t>(fpga_map::word_mask);
    if (!force && known_[address] && value_[address] == raw) {
        return true; // already there
    }
    value_[address]   = raw;
    known_[address]   = false;
    pending_[address] = true;
    return true;
}

bool EngineImage::known(int address, int32_t *raw) const {
    if (address < 0 || address >= words || !known_[address]
        || pending_[address]) {
        return false;
    }
    *raw = value_[address];
    return true;
}

void EngineImage::resend_all() {
    for (int address = 0; address < words; ++address) {
        if (known_[address]) {
            known_[address]   = false;
            pending_[address] = true;
        }
    }
}

int EngineImage::send(EnginePort &port, int limit, fpga_map::dword_t ctrl_bits) {
    // Every dword carries its own address, so a burst takes the pending
    // words as they come, consecutive or not.
    int sent = 0;
    std::array<fpga_map::dword_t, burst_dwords> burst;
    int count = 0;
    for (int address = 0; address < words && sent + count < limit; ++address) {
        if (!pending_[address]) {
            continue;
        }
        burst[count++]    = fpga_map::fifo_dword(address, static_cast<uint32_t>(value_[address]));
        pending_[address] = false;
        known_[address]   = true;
        if (count == burst_dwords) {
            port.queue(burst.data(), count);
            sent += count;
            count = 0;
        }
    }
    if (count > 0) {
        port.queue(burst.data(), count);
        sent += count;
    }
    if (sent > 0) {
        port.write_register(fpga_map::ctrl, ctrl_bits | fpga_map::ctrl_swap);
    }
    return sent;
}
