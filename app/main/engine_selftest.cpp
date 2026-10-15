// engine_selftest.cpp — the CSP's boot self-test
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "engine_selftest.hpp"

#include <array>
#include <cstdio>

#include "csp/lfo.hpp"
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
        check_halves();
        check_lfos();
        return result_;
    }

private:
    void queue(int address, int32_t raw) {
        port_.write_word(static_cast<uint16_t>(fpga_map::queue_base + address),
                         static_cast<uint32_t>(raw) & word_mask);
    }

    void queue_wide(int address, int64_t raw36) {
        queue(address, static_cast<int32_t>(raw36 >> 18));
        queue(address + 1, static_cast<int32_t>(raw36 & word_mask));
    }

    // The program and the constants, and the LFOs: LFO 1 a triangle in the
    // first half, LFO 2 a saw in the second.
    void load() {
        port_.write_word(fpga_map::ctrl, fpga_map::ctrl_hold);
        uint32_t high = 0xFFFFFFFF;
        for (size_t pc = 0; pc < st::words.size(); ++pc) {
            const uint64_t word = st::words[pc];
            if (static_cast<uint32_t>(word >> 32) != high) {
                high = static_cast<uint32_t>(word >> 32);
                port_.write_word(fpga_map::program_high, high);
            }
            port_.write_word(static_cast<uint16_t>(fpga_map::program_base + pc),
                             static_cast<uint32_t>(word));
        }
        for (const st::Constant &constant : st::constants) {
            queue(constant.address, constant.raw);
        }
        constexpr int one = 0x4000; // 1.0 in Q4.14
        for (int half = 0; half < 2; ++half) {
            const int record = st::lfos + half * 16 * st::lfo_size;
            const int set    = st::lfo_sets + half * st::set_size;
            queue_wide(record + st::phase_step, csp::lfo_rate(350, 2));
            queue(record + st::depth, one);
            queue(record + st::neg_depth, -one);
            queue(record + st::gain, half == 0 ? one / 4 : one / 8);
            queue(set + st::base, record);
            queue(set + (half == 0 ? st::n_triangle : st::n_saw), 1);
        }
        port_.write_word(fpga_map::ctrl,
                         fpga_map::ctrl_hold | fpga_map::ctrl_swap);
        port_.wait_ms(2);
        port_.write_word(fpga_map::ctrl, 0); // release
    }

    void note(bool ok, const char *what, long got, long want) {
        char line[96];
        std::snprintf(line, sizeof line, "%s %s (got %ld, want %ld)",
                      ok ? "ok  " : "FAIL", what, got, want);
        result_.lines.emplace_back(line);
        result_.passed = result_.passed && ok;
    }

    void note(bool ok, const char *what) {
        char line[96];
        std::snprintf(line, sizeof line, "%s %s", ok ? "ok  " : "FAIL", what);
        result_.lines.emplace_back(line);
        result_.passed = result_.passed && ok;
    }

    // Instructions, one after another in a chain.
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

    // The half the LFOs work: it must follow the pass counter's low bit, and
    // the chain from it to the set must follow in step.
    void check_halves() {
        std::array<int, 2> bit_seen{};
        std::array<int, 2> half_seen{};
        bool chain_ok = true;
        for (int sample = 0; sample < 8; ++sample) {
            ++bit_seen[(port_.probe(st::res_pass_bit) >> 18) & 1];
            ++half_seen[(signed_word(port_.probe(st::res_half) >> 18) == 8)
                                ? 1
                                : 0];
            const long chain = signed_word(port_.probe(st::res_chain) >> 18);
            chain_ok         = chain_ok && (chain == 16384 || chain == 2056);
        }
        note(bit_seen[0] > 0 && bit_seen[1] > 0,
             "the pass counter's low bit changes");
        note(half_seen[0] > 0 && half_seen[1] > 0,
             "the half's choice alternates (ANDXOR, SHIFT)");
        note(chain_ok, "the table read through IDX follows the half");
    }

    // The LFOs themselves: the triangle's scratch word and output, the saw's
    // phase.
    void check_lfos() {
        const int triangle  = st::lfos;
        const int saw       = st::lfos + 16 * st::lfo_size;
        bool triangle_moves = false;
        long out_first      = 0;
        for (int sample = 0; sample < 8; ++sample) {
            const long t = signed_word(port_.probe(triangle + st::p));
            const long out =
                    signed_word(port_.probe(triangle + st::gain) & word_mask);
            if (sample == 0) {
                out_first = out;
            }
            triangle_moves = triangle_moves || t != 0 || out != out_first;
        }
        note(triangle_moves,
             "LFO 1 (triangle) has a scratch word and an output that move");
        const uint64_t first = port_.probe(saw + st::phase);
        port_.wait_ms(5);
        const uint64_t second = port_.probe(saw + st::phase);
        note(first != second,
             "LFO 2 (saw, the second half) has a phase that advances");
        const uint64_t first_1 = port_.probe(triangle + st::phase);
        port_.wait_ms(5);
        const uint64_t second_1 = port_.probe(triangle + st::phase);
        note(first_1 != second_1,
             "LFO 1 (the first half) has a phase that advances");
    }

    SelfTestPort &port_;
    SelfTestResult result_;
};

} // namespace

SelfTestResult run_selftest(SelfTestPort &port) {
    SelfTestResult result = Run(port).run();
    port.write_word(fpga_map::ctrl, fpga_map::ctrl_hold);
    return result;
}
