// csp_rtl.hpp — the Verilated CSP (tb_csp_cosim.sv) driven from C++
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// What the firmware does to the chip, done to the ports: hold it, load the
// instruction rows and the decode ROM's over the SPI clock, write registers
// through the FIFO and swap, run passes of 1536 clocks, release. The state a
// pass leaves is read back through the bench's DPI functions. Include after
// the Verilated model's headers.

#pragma once

#include <cstdint>

#include "Vtb_csp_cosim.h"
#include "Vtb_csp_cosim__Dpi.h"
#include "csp/csp.hpp"
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
        top_.imem_load  = 0;
        top_.rom_load   = 0;
        top_.fifo_write = 0;
        top_.swap       = 0;
        top_.eval();
        top_.reset_n = 0;
        top_.eval();
        for (int cycle = 0; cycle < 4; ++cycle) tick();
        top_.reset_n = 1;
        tick();
        svSetScope(svGetScopeFromName("TOP.tb_csp_cosim"));
    }

    void hold(bool held) { top_.held = held ? 1 : 0; }

    // The program: its rows, END included — what an earlier, longer program
    // left past them stays in IMEM and never runs (#271) — and the decode ROM.
    void load(const csp::Image &image) {
        for (size_t row = 0; row < static_cast<size_t>(image.length); ++row) {
            top_.imem_load  = 1;
            top_.imem_row   = static_cast<uint32_t>(row);
            top_.imem_upper = 1;
            top_.imem_dword = image.rows[row].high;
            spi_clock();
            top_.imem_upper = 0;
            top_.imem_dword = image.rows[row].low;
            spi_clock();
        }
        top_.imem_load = 0;
        for (size_t row = 0; row < csp::op_count; ++row) {
            top_.rom_load = 1;
            top_.rom_row  = static_cast<uint32_t>(row);
            top_.rom_word = image.rom[row];
            spi_clock();
        }
        top_.rom_load = 0;
        cosim_set_program_length(image.length);
    }

    // A register write for the FIFO's door: the address in bits 35:24, the word in 23:6.
    void write(int address, int32_t raw) {
        top_.fifo_write = 1;
        top_.fifo_dword = (static_cast<uint64_t>(address & 0xFFF) << 24) | (static_cast<uint64_t>(raw & 0x3FFFF) << 6);
        spi_clock();
        top_.fifo_write = 0;
    }

    void swap() {
        top_.swap = 1;
        spi_clock();
        top_.swap = 0;
    }

    // A pass: its start, then its csp::cycles_per_pass cycles.
    void pass() {
        top_.pass_start = 1;
        tick();
        top_.pass_start = 0;
        for (int cycle = 0; cycle < csp::cycles_per_pass; ++cycle) tick();
    }

    int32_t reg(int address) const { return cosim_register(address); }
    int32_t sink(int offset) const { return cosim_sink(offset); }
    int index(int which) const { return cosim_index(which); }
    int flags() const { return cosim_flags(); }
    int cycles() const { return cosim_cycles(); }
    int row_rule_violations() const { return cosim_row_rule_violations(); }
    int fifo_dropped() const { return cosim_fifo_dropped(); }

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
