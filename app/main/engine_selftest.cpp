// engine_selftest.cpp — the CSP's boot self-test
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "engine_selftest.hpp"

#include <array>
#include <cstdio>

#include "csp/selftest_program.hpp"
#include "fpga_map.hpp"

namespace {

namespace st = csp::selftest;

constexpr int word_mask = 0x3FFFF;

int32_t signed_word(uint64_t raw18) {
    const int32_t word = static_cast<int32_t>(raw18 & word_mask);
    return word >= (1 << 17) ? word - (1 << 18) : word;
}

class Run {
public:
    explicit Run(SelfTestPort &port) : port_(port) {}

    SelfTestResult run() {
        load();
        port_.wait_ms(30);
        check_instructions();
        const Counts first = counts();
        port_.wait_ms(100);
        check_halves(first, counts());
        return result_;
    }

private:
    void queue(int address, int32_t raw) {
        port_.write_quad(fpga_map::fifo_door, fpga_map::fifo_quad(address, static_cast<uint32_t>(raw)));
    }

    // The program: its rows into IMEM (two quads a row, bits 71:36 first),
    // its control words into the decode ROM, and NOP rows past both, since
    // what an earlier program left there would run after it on a chip that
    // has not been reset. The program's constants are immediates in its rows.
    void load() {
        port_.write_quad(fpga_map::ctrl, fpga_map::ctrl_hold);
        for (size_t pc = 0; pc < fpga_map::program_rows; ++pc) {
            const csp::Row row = pc < st::rows.size() ? st::rows[pc] : csp::Row{};
            port_.write_quad(fpga_map::program_base + 2 * pc, row.high);
            port_.write_quad(fpga_map::program_base + 2 * pc + 1, row.low);
        }
        for (size_t row = 0; row < fpga_map::rom_rows; ++row) {
            port_.write_quad(fpga_map::rom_base + row, row < st::rom.size() ? st::rom[row] : 0);
        }
        // The counters start at zero, whatever was there.
        for (const int counter_register :
             {st::count_total, st::count_odd, st::count_half_odd, st::count_chain_odd}) {
            queue(counter_register, 0);
        }
        port_.write_quad(fpga_map::ctrl, fpga_map::ctrl_hold | fpga_map::ctrl_swap);
        port_.wait_ms(2);
        port_.write_quad(fpga_map::ctrl, 0); // release
    }

    void note(bool ok, const char *what, long got, long want) {
        char line[96];
        std::snprintf(line, sizeof line, "%s %s (got %ld, want %ld)", ok ? "ok  " : "FAIL", what, got, want);
        result_.lines.emplace_back(line);
        result_.passed = result_.passed && ok;
    }

    void note(bool ok, const char *what) {
        char line[96];
        std::snprintf(line, sizeof line, "%s %s", ok ? "ok  " : "FAIL", what);
        result_.lines.emplace_back(line);
        result_.passed = result_.passed && ok;
    }

    // Instructions, one after another in a chain, as the schedule placed
    // them: a wrong latency shows as a wrong result.
    void check_instructions() {
        const long abs  = signed_word(port_.probe(st::res_abs) >> 18);
        const long mac  = signed_word(port_.probe(st::res_mac) >> 18);
        const long add3 = signed_word(port_.probe(st::res_add3) >> 18);
        const long sel  = signed_word(port_.probe(st::res_sel) >> 18);
        note(abs == 65536, "ABS of -4.0", abs, 65536);
        note(mac == 8192, "MAC after it, 4.0 x 0.125", mac, 8192);
        note(add3 == -57344, "ADD3 after that, 0.5 - 4.0", add3, -57344);
        note(sel == 2048, "SEL after a CMP", sel, 2048);
    }

    // A counter of the self-test program (an even register, an 18-bit word).
    long counter(int address) {
        return static_cast<long>(port_.probe(address) >> 18) & word_mask;
    }

    struct Counts {
        long total, odd, half_odd, chain_odd;
    };

    Counts counts() {
        return {counter(st::count_total), counter(st::count_odd), counter(st::count_half_odd),
                counter(st::count_chain_odd)};
    }

    // The pass counter's low bit: over a stretch of passes, as many odd as
    // even (the program counts them itself, so that when the firmware looks
    // does not matter), and the half's choice and the table read, which come
    // from that bit through ANDXOR, SHIFT and IDX, agree with it.
    void check_halves(const Counts &first, const Counts &second) {
        const long total     = (second.total - first.total) & word_mask;
        const long odd       = (second.odd - first.odd) & word_mask;
        const long half_odd  = (second.half_odd - first.half_odd) & word_mask;
        const long chain_odd = (second.chain_odd - first.chain_odd) & word_mask;
        char line[96];
        std::snprintf(line, sizeof line, "%ld passes, %ld with the pass counter's low bit set", total, odd);
        note(total > 1000 && odd * 100 > total * 45 && odd * 100 < total * 55,
             "the pass counter's low bit is set in half of the passes (ANDXOR)");
        result_.lines.emplace_back(line);
        note(half_odd >= odd - 2 && half_odd <= odd + 2, "the half's choice follows it (SHIFT)", half_odd, odd);
        note(chain_odd >= odd - 2 && chain_odd <= odd + 2, "the table read follows it (IDX)", chain_odd, odd);
    }

    SelfTestPort &port_;
    SelfTestResult result_;
};

} // namespace

SelfTestResult run_selftest(SelfTestPort &port, bool leave_running) {
    SelfTestResult result = Run(port).run();
    if (!leave_running) {
        port.write_quad(fpga_map::ctrl, fpga_map::ctrl_hold);
    }
    return result;
}
