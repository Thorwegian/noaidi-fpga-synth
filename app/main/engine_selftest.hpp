// engine_selftest.hpp — the CSP's boot self-test
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Loads tools/csp/programs/selftest.s (the LFOs, and some instructions in
// dependent chains), lets it run, and reads its registers back through the
// probe (docs/memory_map.md): does the chip do what the model says? The
// system bench (rtl/tb/synth) runs the same code on the simulated chip; the
// firmware runs it on the board at boot, and logs what it finds.

#pragma once

#include <cstdint>
#include <string>
#include <vector>

// How the test reaches the chip.
class SelfTestPort {
public:
    virtual ~SelfTestPort() = default;
    // A quad to an address of the SPI map (fpga_map.hpp).
    virtual void write_quad(uint32_t address, uint64_t value) = 0;
    // Let the chip run.
    virtual void wait_ms(int milliseconds) = 0;
    // The CSP register pair at `register_address` (even), as the probe reads
    // it: the even register in bits 35:18, the odd one in 17:0.
    virtual uint64_t probe(int register_address) = 0;
};

struct SelfTestResult {
    bool passed = true;
    std::vector<std::string> lines; // what was checked, one line each
};

// Leaves the CSP held, with the self-test's program in its memory; the caller
// loads the control program over it. With `leave_running`, the CSP is left
// running the self-test's program instead (to look at its registers).
SelfTestResult run_selftest(SelfTestPort &port, bool leave_running = false);
