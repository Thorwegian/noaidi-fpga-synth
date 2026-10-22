// csp.hpp — the CSP's instruction word, operands, control words and formats
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Shared by the firmware, which generates CSP programs as machine code
// (program_builder.hpp), and the host tools in tools/csp (the reference
// model and the macro assembler). docs/csp2_isa.md is the specification:
// section 2 for the word, 3 for the operands, 4 for the control word and
// the operations, 8 for the latencies.

#pragma once

#include <array>
#include <cstdint>
#include <string_view>

namespace csp {

// ---- sizes ---------------------------------------------------------------

constexpr int register_count = 2048;  // DMEM: 0x000–0x7FF
constexpr int sink_base      = 0x800; // the sink area: 0x800–0xBFF
constexpr int sink_count     = 1024;
constexpr int address_space  = 4096;  // what i and j can address
constexpr int io_base        = 0x040; // read-only inputs
constexpr int io_count       = 32;
constexpr int direct_reach   = 1024;  // a direct operand: 0–1023
constexpr int program_rows   = 1472;  // instructions a pass
constexpr int rom_rows       = 1024;  // the decode ROM's block: 1024 × 18
constexpr int op_count       = 256;   // the rows the word's 8-bit op reaches
constexpr int write_window   = 48;    // queued writes a pass
constexpr int cycles_per_pass = 1536; // one 48 kHz sample
constexpr int pass_cycle_limit = 1472; // instructions issue before this
constexpr int vector_round   = 16;    // elements in flight in a vector loop

// The decode ROM's rows for the vector loops, the same in every program: the
// chip's front end knows a vector loop by its op field, one cycle after the
// row is captured and before the ROM has decoded it (rtl/csp/csp_core.sv).
constexpr uint16_t op_vector_loop_i = 1;
constexpr uint16_t op_vector_loop_j = 2;
constexpr int      rom_reserved     = 3;   // row 0 (NOP) and the two

// ---- the pipeline's timing (rtl/csp/csp_core.sv) ---------------------------
//
// The chip has no interlock: the assembler places every instruction so
// that what it reads has been written (docs/csp2_isa.md section 8). An
// instruction issued at cycle c has its result in DMEM for an instruction
// issued at c + result_latency; its flags and the accumulator are readable
// at c + state_latency; an IDX's index is used at c + index_latency, which
// the assembler lays after it as four wait rows (the chip has no stall); a loop's repeat and a skip's jump
// cost jump_penalty cycles over moving on to the next word. A vector loop
// issues each body row once an element of the round, one cycle each, after
// one bubble behind the first row's first element (the front end knows the
// loop one cycle late), and costs nothing to leave.

constexpr int result_latency = 9;
constexpr int state_latency  = 7;
constexpr int index_latency  = 5;   // the IDX sum is registered into E1b (#238); the assembler and the model follow this one constant
constexpr int jump_penalty   = 4;

// ---- number formats -------------------------------------------------------
//
// word         18 bits  Q4.14
// wide         36 bits  Q4.32  (an aligned register pair, upper word even)
// accumulator  54 bits  Q8.46

constexpr int word_bits                 = 18;
constexpr int wide_bits                 = 36;
constexpr int accumulator_bits          = 54;
constexpr int word_fraction_bits        = 14;
constexpr int wide_fraction_bits        = 32;
constexpr int accumulator_fraction_bits = 46;

// The value of 1.0 as a raw word.
constexpr int32_t word_one = 1 << word_fraction_bits;

// A raw value sign-extended from its low `bits` bits.
constexpr int64_t sign_extend(int64_t value, int bits) {
    const int64_t mask = (int64_t{1} << bits) - 1;
    const int64_t sign = int64_t{1} << (bits - 1);
    value &= mask;
    return (value ^ sign) - sign;
}

constexpr int64_t largest(int bits) {
    return (int64_t{1} << (bits - 1)) - 1;
}

constexpr int64_t smallest(int bits) {
    return -(int64_t{1} << (bits - 1));
}

// ---- the operations -------------------------------------------------------
//
// What a program writes; each becomes one or more decode ROM rows by its
// variant (in place, wide, from the accumulator).

enum class Op : uint8_t {
    nop,
    mac,     // R = A + X × Y, saturating
    macw,    // R = A + X × Y, wrapping
    acc,     // accumulator = A + X × Y
    add3,    // R = A + X + Y
    cmp,     // R = X − Y, the flags set
    abs,     // R = |X|
    min,     // R = X < Y ? X : Y
    max,     // R = X > Y ? X : Y
    sel,     // R = cond clear ? X : Y
    andxor,  // R = (X & Y) ^ A
    shift,   // R = A × 2^Y
    loop,    // a scalar loop on i or j
    vloop,   // a vector loop on i or j
    skip,    // the next n instructions are no-ops when cond holds
    idx,     // i or j = X + Y
};

std::string_view mnemonic(Op op);

// Which value is the A operand of an arithmetic operation.
enum class ASource : uint8_t {
    zero        = 0,
    result      = 1, // A = R: update in place
    accumulator = 2,
};

// The flag a conditional tests (the word's `cond` field).
enum class Condition : uint8_t {
    always   = 0,
    negative = 1,
    positive = 2, // N clear
    zero     = 3,
    nonzero  = 4,
    overflow = 5,
};

enum class IndexRegister : uint8_t { i = 0, j = 1 };

// ---- operands (docs/csp2_isa.md section 3) ---------------------------------
//
// A 12-bit field: a 2-bit mode and 10 bits. Mode 0 names a register
// directly (0–1023); modes 1 and 2 put the offset's bits beside the index
// register's; mode 3 is the word's immediate in x or y, and "no result" in r.

struct Operand {
    enum class Mode : uint8_t { direct = 0, i = 1, j = 2, immediate = 3 } mode = Mode::direct;
    int value = 0; // the address, the offset, or nothing

    static Operand direct(int address) { return {Mode::direct, address}; }
    static Operand indexed(IndexRegister index, int offset) {
        return {index == IndexRegister::i ? Mode::i : Mode::j, offset};
    }
    static Operand immediate() { return {Mode::immediate, 0}; }
    static Operand none() { return {Mode::immediate, 0}; }

    bool is_indexed() const { return mode == Mode::i || mode == Mode::j; }
    IndexRegister index() const { return mode == Mode::j ? IndexRegister::j : IndexRegister::i; }

    uint16_t encode() const;
    static Operand decode(uint16_t field);
    bool operator==(const Operand &) const = default;
};

// ---- the control word (docs/csp2_isa.md section 4) -------------------------
//
// One row of the decode ROM: what the datapath does for an `op`.

enum class Unit : uint8_t {
    none         = 0,
    multiply_add = 1, // MAC, MACW, ACC, ADD3, CMP, ABS: through the DSP
    logic        = 2, // MIN, MAX, SEL, ANDXOR
    shift        = 3,
    loop         = 4,
    skip         = 5,
    index        = 6,
};

enum class Writes : uint8_t {
    nothing     = 0,
    word        = 1, // a register (or a sink word, by the address)
    pair        = 2, // a wide register
    index_i     = 3,
    index_j     = 4,
    accumulator = 5,
};

enum class ConditionKind : uint8_t {
    none   = 0,
    select = 1, // SEL chooses by cond
    skip   = 2, // SKIP skips by cond
    flags  = 3, // the result sets the flags
};

// The multiply-add unit's sub-operations.
enum class MultiplyAddOp : uint8_t { mac = 0, add3 = 2, cmp = 3, abs = 4 };   // 1 was INTERP, dropped (#238)
// The logic unit's.
enum class LogicOp : uint8_t { min = 0, max = 1, sel = 2, andxor = 3 };
// The loop unit's.
enum class LoopOp : uint8_t { scalar_i = 0, scalar_j = 1, vector_i = 2, vector_j = 3 };

struct Control {
    Unit unit             = Unit::none;    // [17:15]
    Writes writes         = Writes::nothing; // [14:12]
    ASource a_source      = ASource::zero; // [11:10]
    bool reads_x          = false;         // [9]  X is read (from DMEM, or the immediate)
    bool y_wide           = false;         // [8]
    ConditionKind cond    = ConditionKind::none; // [7:6]
    bool reads_y          = false;         // [5]  Y is read
    bool wrap             = false;         // [3]
    uint8_t sub           = 0;             // [2:0]

    uint32_t encode() const;
    static Control decode(uint32_t row);
    bool operator==(const Control &) const = default;
};

// The control word of an operation in a variant: wide (R and Y are pairs,
// X a word) and the A source. Operations without a variant ignore them.
Control control_of(Op op, bool wide, ASource a_source);

// ---- the instruction word (docs/csp2_isa.md section 2) ---------------------
//
//   [71:64] op   the decode ROM row
//   [63:60] cond
//   [59:48] r    [47:36] x   [35:24] y
//   [23:0]  imm  an 18-bit immediate; a loop's or a skip's end

struct Row {
    uint64_t high = 0; // bits 71:36, the first dword on the wire
    uint64_t low  = 0; // bits 35:0, the second
    bool operator==(const Row &) const = default;
};

struct Word {
    uint16_t op    = 0; // the ROM row, 8 bits
    uint8_t cond   = 0; // 4 bits
    Operand r, x, y;
    uint32_t imm   = 0; // 24 bits

    Row encode() const;
    static Word decode(const Row &row);
    bool operator==(const Word &) const = default;
};

// A loop's numbers: its body's last row in imm, its count in x's ten bits
// and its stride in y's (docs/csp2_isa.md section 5). A skip's count in imm.
constexpr int loop_count_max  = 1023;
constexpr int loop_stride_max = 511;   // signed, ten bits

// ---- an image: the program and its decode ROM ------------------------------

struct Image {
    std::array<Row, program_rows> rows{};   // the program, NOPs past its end
    std::array<uint32_t, rom_rows> rom{};   // the control words; row 0 is NOP
    int length   = 0;                       // rows the program uses
    int rom_used = 1;                       // rows the ROM uses
};

} // namespace csp
