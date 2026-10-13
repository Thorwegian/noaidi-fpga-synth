// csp_cosim.cpp — the new CSP's RTL against tools/csp's reference model
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Runs the same programs and firmware writes on the RTL (Verilated
// tb_csp_cosim.sv) and on the reference model, and after every pass
// compares everything a program can leave behind: all 2048 registers, the
// published sink page, i, j, the accumulator and the flags. Programs come
// from two places: the manual's examples, assembled, and random programs
// built with csp::ProgramBuilder, as the firmware will build them.
//
//   make sim-csp-cosim            (rtl/Makefile)
//   obj_dir/csp_cosim/sim [seed] [programs]     (default: seed 1, 200 programs)

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <vector>

#include "Vtb_csp_cosim.h"
#include "Vtb_csp_cosim__Dpi.h"
#include "assembler.hpp"
#include "csp/program_builder.hpp"
#include "processor.hpp"
#include "svdpi.h"
#include "verilated.h"

namespace {

// ---- the RTL ------------------------------------------------------------------

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

// ---- one run: a program on both, pass by pass ----------------------------------------------

struct FirmwareWrite {
    int address;
    int32_t raw;
};

class CoSim {
public:
    explicit CoSim(VerilatedContext &context) : rtl_(context) {}

    // Load constants and the program while held, then release.
    void start(const std::vector<uint64_t> &words,
               const std::vector<FirmwareWrite> &setup) {
        rtl_.hold(true);
        rtl_.load(words);
        model_.load(words);
        for (const FirmwareWrite &write : setup) {
            rtl_.write(write.address, write.raw);
            model_.write(write.address, write.raw);
        }
        rtl_.swap();
        model_.swap();
        rtl_.pass();
        model_.pass(); // held: applies the setup
        rtl_.hold(false);
        model_.release();
    }

    // One pass, after queueing writes and swapping (if any). Returns the
    // number of differences, printing the first few.
    int pass(const std::vector<FirmwareWrite> &writes,
             const std::string &what) {
        for (const FirmwareWrite &write : writes) {
            rtl_.write(write.address, write.raw);
            model_.write(write.address, write.raw);
        }
        if (!writes.empty()) {
            rtl_.swap();
            model_.swap();
        }
        rtl_.pass();
        const csp::PassReport report = model_.pass();
        if (!report.errors.empty() && verbose_) {
            std::printf("  (model: %s)\n", report.errors.front().c_str());
        }
        int differences = compare(what);
        // The interlocks' timing: the RTL issues its last instruction in the
        // cycle the model counts. (A pass the model stopped at the limit
        // ends differently: the RTL runs on through memory past the
        // program, which may hold anything.)
        if (report.errors.empty() && rtl_.cycles() != report.cycles) {
            std::printf("  %s: cycles rtl %d model %d\n", what.c_str(),
                        rtl_.cycles(), report.cycles);
            ++differences;
        }
        return differences;
    }

    void verbose(bool on) {
        verbose_ = on;
    }

    void trace(bool on) {
        model_.trace(on);
    }

private:
    int compare(const std::string &what) {
        int differences = 0;
        auto report     = [&](const std::string &where, int64_t rtl,
                          int64_t model) {
            if (differences < 8) {
                std::printf("  %s: %s rtl %" PRId64 " model %" PRId64 "\n",
                                what.c_str(), where.c_str(), rtl, model);
            }
            ++differences;
        };
        for (int address = 0; address < csp::register_count; ++address) {
            if (rtl_.reg(address) != model_.read(address)) {
                char where[32];
                std::snprintf(where, sizeof where, "register 0x%03x", address);
                report(where, rtl_.reg(address), model_.read(address));
            }
        }
        for (int offset = 0; offset < csp::sink_count; ++offset) {
            if (rtl_.sink(offset) != model_.sink(offset)) {
                char where[32];
                std::snprintf(where, sizeof where, "sink 0x%03x", offset);
                report(where, rtl_.sink(offset), model_.sink(offset));
            }
        }
        if (rtl_.index(0) != model_.index(csp::IndexRegister::i)) {
            report("i", rtl_.index(0), model_.index(csp::IndexRegister::i));
        }
        if (rtl_.index(1) != model_.index(csp::IndexRegister::j)) {
            report("j", rtl_.index(1), model_.index(csp::IndexRegister::j));
        }
        if (rtl_.accumulator() != model_.accumulator()) {
            report("accumulator", rtl_.accumulator(), model_.accumulator());
        }
        const csp::Flags flags = model_.flags();
        const int model_flags  = (flags.negative ? 1 : 0) | (flags.zero ? 2 : 0)
                                | (flags.overflow ? 4 : 0);
        if (rtl_.flags() != model_flags) {
            report("flags", rtl_.flags(), model_flags);
        }
        return differences;
    }

    Rtl rtl_;
    csp::Processor model_;
    bool verbose_ = false;
};

// ---- directed programs: the manual's examples ------------------------------------------------
// The envelope is written as LOOP.i: the RTL has no vector loops yet.

const char *envelope_program = R"(
        .block VOICE
        .field LEVEL, 2
        .field STAGE, 1
        .field GATE, 1
        .field VELOCITY, 1
        .field OUT, 1
        .end
        .block SEGMENT
        .field TARGET, 2
        .field RATE, 1
        .field SPARE, 1
        .end
        .equ   VOICES, 0x600
        .const FULL, 1.0
        .reg   ENV_TABLE, 0x060
        .reg   U, 0x061

        IDX     i, =#VOICES, 0
        NOP
        NOP
        NOP
        LOOP.i  done, =#4, =#16
        IDX     j, ENV_TABLE, [i+STAGE]
        MAX     U, [i+STAGE], =#4
        CMP     ZERO, [i+LEVEL], FULL
        SEL     [i+STAGE], U, [i+STAGE]
        ANDXOR  U, 0, [i+STAGE], =#4
        CMP     ZERO, [i+GATE], FULL
        SEL     [i+STAGE], U, =#8
        INTERP.w [i+LEVEL], [j+RATE], [j+TARGET]
        MAC     [i+OUT], 0, [i+LEVEL], [i+VELOCITY]
done:
        IDX     j, =#0x800, 0
        NOP
        NOP
        NOP
        MAC     [j+0], 0, [i+0], =1.0       ; i is past the voices: a sink write
)";

const char *lfo_program = R"(
        .wide  PHASE, 0x060
        .wide  RATE, 0x062
        .reg   SAW, 0x064
        .reg   SQUARE, 0x065
        .reg   T, 0x066
        .reg   TRI, 0x067
        .const ONE, 1.0
        .const DEPTH, 1.0
        .const NEG_DEPTH, -1.0
        .const DEPTH_8, 0.125
        .const DEPTH_4, 0.25

        MACW.w  PHASE, ONE, RATE
        MAC     SAW, 0, PHASE, DEPTH_8
        CMP     ZERO, PHASE, ZERO
        SEL     SQUARE, DEPTH, NEG_DEPTH
        ABS     T, PHASE
        MAC     TRI, 0, T, DEPTH_4
        ADD3    TRI, TRI, NEG_DEPTH, ZERO
        SHIFT   T, T, =#-3
        ACC     0, SAW, =0.5
        ACC     acc, SQUARE, =0.5
        MAC     0x068, acc, TRI, =0.5
)";

std::vector<FirmwareWrite> constants_of(const csp::Program &program) {
    std::vector<FirmwareWrite> writes;
    for (const csp::ConstantWrite &constant : program.constants) {
        writes.push_back({constant.address, constant.raw});
    }
    return writes;
}

// ---- random programs ---------------------------------------------------------------------------
//
// Register plan: constants 0x001–0x03F (random values, set by the
// firmware), with loop counts and strides at fixed places; work words
// 0x060–0x0DF; wide pairs 0x0E0–0x0FF; i starts at 0x200, j at 0x300
// (blocks the programs index into), or at 0x800 for sink writes.

constexpr int count_base  = 0x030; // 0x030–0x033: loop counts 1–4
constexpr int stride_base = 0x034; // 0x034–0x037: strides 2, 4, −2, 16
constexpr int base_i      = 0x038; // holds 0x200
constexpr int base_j      = 0x039; // holds 0x300
constexpr int base_sink   = 0x03A; // holds 0x800

class Generator {
public:
    explicit Generator(uint32_t seed) : random_(seed) {}

    std::vector<FirmwareWrite> setup() {
        std::vector<FirmwareWrite> writes;
        for (int address = 0x001; address < count_base; ++address) {
            writes.push_back({address, word()});
        }
        for (int count = 0; count < 4; ++count) {
            writes.push_back({count_base + count, count + 1});
        }
        const int strides[] = {2, 4, -2, 16};
        for (int n = 0; n < 4; ++n) {
            writes.push_back({stride_base + n, strides[n]});
        }
        writes.push_back({base_i, 0x200});
        writes.push_back({base_j, 0x300});
        writes.push_back({base_sink, 0x800});
        for (int address = 0x060; address < 0x100; ++address) {
            writes.push_back({address, word()});
        }
        return writes;
    }

    // A few writes, or now and then a burst past the 48-write window that
    // includes writes the window must drop (register 0, the inputs).
    std::vector<FirmwareWrite> writes_between_passes() {
        std::vector<FirmwareWrite> writes;
        const bool burst = chance(6);
        const int count  = burst ? pick(50, 70) : pick(0, 6);
        for (int n = 0; n < count; ++n) {
            int address = pick(0x060, 0x0FF);
            if (burst && chance(8)) {
                address = chance(2) ? 0 : pick(0x040, 0x05F);
            }
            writes.push_back({address, word()});
        }
        return writes;
    }

    std::vector<uint64_t> program() {
        csp::ProgramBuilder b;
        b.idx(csp::IndexRegister::i, direct(base_i), direct(0));
        b.idx(csp::IndexRegister::j, direct(chance(4) ? base_sink : base_j),
              direct(0));
        const int items = pick(10, 60);
        for (int item = 0; item < items; ++item) {
            const int kind = pick(0, 19);
            if (kind == 0) {
                loop(b, true);
            } else if (kind == 1) {
                skip(b);
            } else {
                instruction(b, false);
            }
        }
        return b.words();
    }

private:
    int pick(int low, int high) {
        return std::uniform_int_distribution<int>(low, high)(random_);
    }
    bool chance(int one_in) {
        return pick(1, one_in) == 1;
    }
    int32_t word() {
        // mostly modest values, sometimes the extremes
        switch (pick(0, 7)) {
        case 0:
            return pick(-131072, 131071);
        case 1:
            return chance(2) ? 131071 : -131072;
        default:
            return pick(-40000, 40000);
        }
    }

    static csp::Operand direct(int address) {
        return csp::Operand::direct(address);
    }

    csp::Operand word_operand() {
        switch (pick(0, 9)) {
        case 0:
            return direct(0);
        case 1:
        case 2:
            return direct(pick(0x001, 0x02F)); // constants
        case 3:
            return csp::Operand::indexed(csp::IndexRegister::i, pick(0, 31));
        case 4:
            return csp::Operand::indexed(csp::IndexRegister::j, pick(0, 31));
        default:
            return direct(pick(0x060, 0x0DF));
        }
    }

    csp::Operand result_operand() {
        switch (pick(0, 9)) {
        case 0:
            return direct(0); // discarded
        case 1:
            return csp::Operand::indexed(csp::IndexRegister::i, pick(0, 31));
        case 2:
        case 3:
            return csp::Operand::indexed(csp::IndexRegister::j, pick(0, 31));
        default:
            return direct(pick(0x060, 0x0DF));
        }
    }

    csp::Operand wide_operand() {
        switch (pick(0, 5)) {
        case 0:
            return csp::Operand::indexed(csp::IndexRegister::i,
                                         2 * pick(0, 15));
        default:
            return direct(0x0E0 + 2 * pick(0, 15));
        }
    }

    csp::ASelect a_select() {
        switch (pick(0, 3)) {
        case 0:
            return csp::ASelect::zero;
        case 1:
            return csp::ASelect::accumulator;
        default:
            return csp::ASelect::result;
        }
    }

    void instruction(csp::ProgramBuilder &b, bool in_loop) {
        const csp::Operand x = word_operand();
        const csp::Operand y = word_operand();
        switch (pick(0, 15)) {
        case 0:
            b.mac(result_operand(), a_select(), x, y);
            break;
        case 1:
            b.macw(result_operand(), a_select(), x, y);
            break;
        case 2:
            b.interp(result_operand(), a_select(), x, y);
            break;
        case 3:
            b.add3(result_operand(), a_select(), x, y);
            break;
        case 4:
            b.acc(chance(2) ? csp::ASelect::zero : csp::ASelect::accumulator, x,
                  y);
            break;
        case 5:
            b.sel(result_operand(), x, y);
            break;
        case 6:
            b.cmp(result_operand(), x, y);
            break;
        case 7:
            chance(2) ? b.min(result_operand(), x, y)
                      : b.max(result_operand(), x, y);
            break;
        case 8:
            b.andxor(result_operand(),
                     chance(2) ? csp::ASelect::zero : a_select(), x, y);
            break;
        case 9:
            b.shift(result_operand(), a_select(), direct(pick(0x001, 0x02F)));
            break;
        case 10:
            b.abs(result_operand(), x);
            break;
        case 11: {
            const csp::Operand wide = wide_operand();
            switch (pick(0, 4)) {
            case 0:
                b.mac_wide(wide, x, wide_operand());
                break;
            case 1:
                b.macw_wide(wide, x, wide_operand());
                break;
            case 2:
                b.interp_wide(wide, x, wide_operand());
                break;
            case 3:
                b.add3_wide(wide, x, wide_operand());
                break;
            default:
                b.shift_wide(wide, direct(pick(0x001, 0x02F)));
                break;
            }
            break;
        }
        case 12:
            if (!in_loop) {
                // re-point i or j at its block, or somewhere random
                const bool on_j = chance(2);
                b.idx(on_j ? csp::IndexRegister::j : csp::IndexRegister::i,
                      direct(chance(3) ? pick(0x060, 0x0DF)
                                       : (on_j ? base_j : base_i)),
                      y);
                break;
            }
            [[fallthrough]];
        default:
            b.mac(result_operand(), a_select(), x, y);
            break;
        }
    }

    void skip(csp::ProgramBuilder &b) {
        const auto condition = static_cast<csp::Condition>(pick(0, 5));
        const int count      = pick(1, 3);
        b.skip(condition, static_cast<size_t>(count));
        for (int n = 0; n < count; ++n) {
            instruction(b, false);
        }
    }

    void loop(csp::ProgramBuilder &b, bool may_nest) {
        const bool on_j = chance(2);
        const size_t at = b.open_loop(on_j ? csp::IndexRegister::j
                                           : csp::IndexRegister::i,
                                      direct(count_base + pick(0, 3)),
                                      direct(stride_base + pick(0, 3)));
        const int body = pick(1, 5);
        for (int n = 0; n < body; ++n) {
            if (may_nest && chance(5)) {
                // the inner loop steps the other index register
                const size_t inner = b.open_loop(
                        on_j ? csp::IndexRegister::i : csp::IndexRegister::j,
                        direct(count_base + pick(0, 2)),
                        direct(stride_base + pick(0, 3)));
                const int inner_body = pick(1, 3);
                for (int m = 0; m < inner_body; ++m) {
                    instruction(b, true);
                }
                b.close_loop(inner);
            } else {
                instruction(b, true);
            }
        }
        b.close_loop(at);
    }

    std::mt19937 random_;
};

} // namespace

int main(int argc, char **argv) {
    VerilatedContext context;
    context.commandArgs(argc, argv);
    // The seed: `+verilator+seed+N` as `make sim` passes it, or a plain
    // first number; a plain second number is how many random programs.
    uint32_t seed = 1;
    int programs  = 200;
    std::vector<std::string> numbers;
    for (int arg = 1; arg < argc; ++arg) {
        const std::string text      = argv[arg];
        const std::string seed_flag = "+verilator+seed+";
        if (text.rfind(seed_flag, 0) == 0) {
            seed = static_cast<uint32_t>(
                    std::strtoul(text.c_str() + seed_flag.size(), nullptr, 10));
        } else if (!text.empty() && text[0] != '+') {
            numbers.push_back(text);
        }
    }
    if (!numbers.empty()) {
        seed = static_cast<uint32_t>(
                std::strtoul(numbers[0].c_str(), nullptr, 10));
    }
    if (numbers.size() > 1) {
        programs = std::atoi(numbers[1].c_str());
    }
    std::printf("SIM_SEED=%u\n", seed);

    int failures = 0;

    // The manual's programs, with firmware writes to drive them.
    {
        const csp::Program envelope      = csp::assemble(envelope_program);
        std::vector<FirmwareWrite> setup = constants_of(envelope);
        setup.push_back({0x060, 0x200}); // ENV_TABLE
        // Rows of the envelope table: target (wide: upper, lower), rate.
        const int table[][2] = {
                {0x200, 21299}, {0x201, 0}, {0x202, 1638}, // attack: 1.3, 0.1
                {0x204, 8192},  {0x205, 0}, {0x206, 819},  // decay: 0.5, 0.05
                {0x208, 0},     {0x209, 0}, {0x20a, 819}}; // release: 0, 0.05
        for (const auto &entry : table) {
            setup.push_back({entry[0], entry[1]});
        }
        for (int voice = 0; voice < 4; ++voice) {
            setup.push_back(
                    {0x600 + 16 * voice + 2, voice == 3 ? 8 : 0}); // stage
            setup.push_back(
                    {0x600 + 16 * voice + 3, voice < 2 ? 16384 : 0}); // gate
            setup.push_back(
                    {0x600 + 16 * voice + 4, 8192 * (voice + 1)}); // velocity
        }
        CoSim cosim(context);
        cosim.start(envelope.words, setup);
        int differences = 0;
        for (int pass = 0; pass < 60 && differences == 0; ++pass) {
            std::vector<FirmwareWrite> writes;
            if (pass == 30) {
                writes.push_back({0x600 + 3, 0}); // voice 0: gate off
            }
            differences =
                    cosim.pass(writes, "envelope pass " + std::to_string(pass));
        }
        std::printf("envelope: %s\n", differences ? "FAIL" : "match");
        failures += differences != 0;
    }
    {
        const csp::Program lfo           = csp::assemble(lfo_program);
        std::vector<FirmwareWrite> setup = constants_of(lfo);
        setup.push_back({0x062, 1});      // RATE, wide: upper word
        setup.push_back({0x063, 0x1234}); //   lower word
        CoSim cosim(context);
        cosim.start(lfo.words, setup);
        int differences = 0;
        for (int pass = 0; pass < 20 && differences == 0; ++pass) {
            differences = cosim.pass({}, "lfo pass " + std::to_string(pass));
        }
        std::printf("lfo: %s\n", differences ? "FAIL" : "match");
        failures += differences != 0;
    }

    // Random programs.
    int matched = 0;
    for (int n = 0; n < programs; ++n) {
        Generator generator(seed * 7919u + static_cast<uint32_t>(n));
        const std::vector<uint64_t> words = generator.program();
        CoSim cosim(context);
        const char *trace = std::getenv("CSP_TRACE_PROGRAM");
        cosim.trace(trace != nullptr && std::atoi(trace) == n);
        cosim.start(words, generator.setup());
        int differences = 0;
        for (int pass = 0; pass < 4 && differences == 0; ++pass) {
            differences = cosim.pass(generator.writes_between_passes(),
                                     "program " + std::to_string(n) + " pass "
                                             + std::to_string(pass));
        }
        if (differences == 0) {
            ++matched;
        } else {
            std::printf("  program %d:\n", n);
            for (size_t at = 0; at < words.size(); ++at) {
                const csp::Instruction ins =
                        csp::Instruction::decode(words[at]);
                std::printf("    %3zu %-6s a=%d r=%03x x=%03x y=%03x\n", at,
                            std::string(csp::mnemonic(ins.op)).c_str(),
                            static_cast<int>(ins.a), ins.r, ins.x, ins.y);
            }
            ++failures;
            if (failures > 5) {
                break;
            }
        }
    }
    std::printf("random programs: %d of %d match\n", matched, programs);

    if (failures) {
        std::printf("%d FAILURE(S)\n", failures);
    } else {
        std::printf("ALL PASS\n");
    }
    return failures ? 1 : 0;
}
