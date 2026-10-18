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
        const Counts first     = counts();
        const uint64_t phase_1 = port_.probe(st::lfos + st::phase);
        const uint64_t phase_2 =
                port_.probe(st::lfos + 16 * st::lfo_size + st::phase);
        port_.wait_ms(100);
        check_halves(first, counts());
        check_lfos(phase_1, phase_2);
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
        // What an earlier program left past the end of this one would run
        // after it, on a chip that has not been reset.
        port_.write_word(fpga_map::program_high, 0);
        for (size_t pc = st::words.size(); pc < fpga_map::program_words; ++pc) {
            port_.write_word(static_cast<uint16_t>(fpga_map::program_base + pc),
                             0);
        }
        for (const st::Constant &constant : st::constants) {
            queue(constant.address, constant.raw);
        }
        // The counters start at zero, whatever was there.
        for (const int counter_register :
             {st::count_total, st::count_odd, st::count_half_odd,
              st::count_chain_odd}) {
            queue(counter_register, 0);
        }
        constexpr int one = 0x4000; // 1.0 in Q4.14
        for (int half = 0; half < 2; ++half) {
            const int record = st::lfos + half * 16 * st::lfo_size;
            const int set    = st::lfo_sets + half * st::set_size;
            // a loop runs over as many records of each shape as the set says:
            // every count must be written, not only the one that is used
            for (int word = 0; word < st::set_size; ++word) {
                queue(set + word, 0);
            }
            queue_wide(record + st::phase_step, int64_t{1} << 22);
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

    // A counter of the self-test program (an even register, an 18-bit word).
    long counter(int address) {
        return static_cast<long>(port_.probe(address) >> 18) & word_mask;
    }

    struct Counts {
        long total, odd, half_odd, chain_odd;
    };

    Counts counts() {
        return {counter(st::count_total), counter(st::count_odd),
                counter(st::count_half_odd), counter(st::count_chain_odd)};
    }

    // The half the LFOs work follows the pass counter's low bit: over a stretch
    // of passes, as many odd as even (the program counts them itself, so that
    // when the firmware looks does not matter), and the half's choice and the
    // table read, which come from that bit through ANDXOR, SHIFT and IDX, agree
    // with it.
    void check_halves(const Counts &first, const Counts &second) {
        const long total     = (second.total - first.total) & word_mask;
        const long odd       = (second.odd - first.odd) & word_mask;
        const long half_odd  = (second.half_odd - first.half_odd) & word_mask;
        const long chain_odd = (second.chain_odd - first.chain_odd) & word_mask;
        char line[96];
        std::snprintf(line, sizeof line,
                      "%ld passes, %ld with the pass counter's low bit set",
                      total, odd);
        note(total > 1000 && odd * 100 > total * 45 && odd * 100 < total * 55,
             "the pass counter's low bit is set in half of the passes (ANDXOR)");
        result_.lines.emplace_back(line);
        note(half_odd >= odd - 2 && half_odd <= odd + 2,
             "the half's choice follows it (SHIFT)", half_odd, odd);
        note(chain_odd >= odd - 2 && chain_odd <= odd + 2,
             "the table read follows it (IDX)", chain_odd, odd);
    }

    // The LFOs themselves: the triangle's scratch word and output move, and the
    // two halves' phases advance at the same rate.
    void check_lfos(uint64_t phase_1, uint64_t phase_2) {
        const int triangle  = st::lfos;
        const int saw       = st::lfos + 16 * st::lfo_size;
        bool triangle_moves = false;
        long out_first      = 0;
        for (int sample = 0; sample < 4; ++sample) {
            const long t = signed_word(port_.probe(triangle + st::p));
            const long out =
                    signed_word(port_.probe(triangle + st::gain) & word_mask);
            if (sample == 0) {
                out_first = out;
            }
            triangle_moves = triangle_moves || t != 0 || out != out_first;
            port_.wait_ms(20);
        }
        note(triangle_moves,
             "LFO 1 (triangle) has a scratch word and an output that move");
        constexpr uint64_t wide_mask = (uint64_t{1} << 36) - 1;
        const uint64_t after_1       = port_.probe(triangle + st::phase);
        const uint64_t after_2       = port_.probe(saw + st::phase);
        const long moved_1 =
                static_cast<long>(((after_1 - phase_1) & wide_mask) >> 20);
        const long moved_2 =
                static_cast<long>(((after_2 - phase_2) & wide_mask) >> 20);
        note(moved_1 > 100 && moved_2 > 100 && moved_1 * 10 < moved_2 * 11
                     && moved_2 * 10 < moved_1 * 11,
             "the two LFO halves' phases advance at the same rate", moved_1,
             moved_2);
    }

    SelfTestPort &port_;
    SelfTestResult result_;
};

} // namespace

SelfTestResult run_selftest(SelfTestPort &port, bool leave_running) {
    SelfTestResult result = Run(port).run();
    if (!leave_running) {
        port.write_word(fpga_map::ctrl, fpga_map::ctrl_hold);
    }
    return result;
}
