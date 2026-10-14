// engine_image.cpp — the register image behind the engine link
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "engine_image.hpp"

namespace {

constexpr int burst_words = 8; // fpga_word_write_burst's per-transaction limit
constexpr int word_mask   = 0x3FFFF; // 18 bits on the wire

} // namespace

bool EngineImage::set(int address, int32_t raw, bool force) {
    if (address < 0 || address >= words) {
        return false;
    }
    raw &= word_mask;
    if (!force && known_[address] && value_[address] == raw) {
        return true; // already there
    }
    value_[address]   = raw;
    known_[address]   = false;
    pending_[address] = true;
    return true;
}

int EngineImage::send(EnginePort &port, int limit, uint32_t ctrl_bits) {
    int sent    = 0;
    int address = 0;
    while (address < words && sent < limit) {
        if (!pending_[address]) {
            ++address;
            continue;
        }
        std::array<uint32_t, burst_words> burst;
        int count       = 0;
        const int start = address;
        while (count < burst_words && address < words && pending_[address]
               && sent + count < limit) {
            burst[count++]    = static_cast<uint32_t>(value_[address]);
            pending_[address] = false;
            known_[address]   = true;
            ++address;
        }
        port.queue_burst(fpga_map::queue_base + start, burst.data(), count);
        sent += count;
    }
    if (sent > 0) {
        port.write_register(fpga_map::ctrl, ctrl_bits | fpga_map::ctrl_swap);
    }
    return sent;
}
