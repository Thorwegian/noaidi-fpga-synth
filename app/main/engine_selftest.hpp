// engine_selftest.hpp — the CSP's boot self-test
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Loads tools/csp/programs/selftest.s (instructions in dependent chains, as
// the assembler scheduled them, and counters that follow the pass counter),
// lets it run, and reads its registers back through the probe
// (docs/memory_map.md): does the chip do what the model says? The firmware
// runs it on the board at boot and logs what it finds; the co-simulation
// (#235) runs the same program on the simulated chip.

#pragma once

#include <cstdint>
#include <string>
#include <vector>

// How the test reaches the chip.
class SelfTestPort {
public:
    virtual ~SelfTestPort() = default;
    // A dword to an address of the SPI map (fpga_map.hpp).
    virtual void write_dword(uint32_t address, uint64_t value) = 0;
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
