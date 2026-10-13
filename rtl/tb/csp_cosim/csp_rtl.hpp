// csp_rtl.hpp — the Verilated CSP (tb_csp_cosim.sv) driven from C++
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Shared by the co-simulation (csp_cosim.cpp), which compares the RTL with
// tools/csp's reference model, and the program benches (csp_bench.cpp),
// which compare it with the fixed-function units it replaces. Include
// after the Verilated model's headers.

#pragma once

#include <cstdint>
#include <vector>

#include "Vtb_csp_cosim.h"
#include "Vtb_csp_cosim__Dpi.h"
#include "processor.hpp"
#include "svdpi.h"
#include "verilated.h"

namespace {

class Rtl {
public:
    explicit Rtl(VerilatedContext &context) : top_(&context) {
        top_.clk        = 0;
        top_.sclk       = 0;
        top_.reset_n    = 1; // then a real falling edge, so the asynchronous
        top_.held       = 1; // resets act (the SPI clock is idle during reset)
        top_.pass_start = 0;
        top_.imem_write_enable  = 0;
        top_.queue_write_enable = 0;
        top_.swap               = 0;
        top_.eval();
        top_.reset_n = 0;
        top_.eval();
        for (int cycle = 0; cycle < 4; ++cycle) {
            tick();
        }
        top_.reset_n = 1;
        tick();
        svSetScope(svGetScopeFromName("TOP.tb_csp_cosim"));
    }

    void hold(bool held) {
        top_.held = held ? 1 : 0;
    }

    void load(const std::vector<uint64_t> &words) {
        for (size_t address = 0; address < words.size(); ++address) {
            top_.imem_write_enable  = 1;
            top_.imem_write_address = static_cast<uint32_t>(address);
            top_.imem_write_data    = words[address];
            spi_clock();
        }
        top_.imem_write_enable = 0;
        cosim_set_program_length(static_cast<int>(words.size()));
    }

    void write(int address, int32_t raw) {
        top_.queue_write_enable  = 1;
        top_.queue_write_address = static_cast<uint32_t>(address);
        top_.queue_write_data    = static_cast<uint32_t>(raw) & 0x3FFFF;
        spi_clock();
        top_.queue_write_enable = 0;
    }

    void swap() {
        top_.swap = 1;
        spi_clock();
        top_.swap = 0;
    }

    // A pass: its 1536 cycles, plus the clock edge that ends the last one,
    // where the sink pages flip (in the design, the next pass's first
    // edge).
    void pass() {
        top_.pass_start = 1;
        tick();
        top_.pass_start = 0;
        for (int cycle = 1; cycle <= csp::cycles_per_pass; ++cycle) {
            tick();
        }
    }

    int32_t reg(int address) const {
        return cosim_register(address);
    }
    int32_t sink(int offset) const {
        return cosim_sink(offset);
    }
    int index(int which) const {
        return cosim_index(which);
    }
    int64_t accumulator() const {
        return cosim_accumulator();
    }
    int flags() const {
        return cosim_flags();
    }
    int cycles() const {
        return cosim_cycles();
    }

    // The adsr.sv references (REF_VOICES > 0): the gate and coefficients of a
    // voice, and its state, {stage[1:0], level[25:0]}.
    void ref_set(int voice, bool gate, uint32_t rate_ad, uint32_t rate_dsr) {
        cosim_ref_set(voice, gate ? 1 : 0, static_cast<int>(rate_ad),
                      static_cast<int>(rate_dsr));
    }
    uint32_t ref_state(int voice) const {
        return static_cast<uint32_t>(cosim_ref_state(voice));
    }

private:
    void tick() {
        top_.clk = 0;
        top_.eval();
        top_.clk = 1;
        top_.eval();
    }

    void spi_clock() {
        top_.sclk = 1;
        top_.eval();
        top_.sclk = 0;
        top_.eval();
    }

    Vtb_csp_cosim top_;
};

} // namespace
