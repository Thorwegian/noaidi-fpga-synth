// csp.hpp — the CSP's instruction word, operands and number formats
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Shared by the reference model (processor.hpp) and the assembler
// (assembler.hpp). docs/csp_manual.md is the specification: section 3
// for the formats, section 4 for the instruction word and operands,
// section 9 for the opcodes.

#pragma once

#include <cstdint>
#include <string_view>

namespace csp {

// ---- sizes ---------------------------------------------------------------

constexpr int register_count     = 2048;  // 0x000–0x7FF
constexpr int sink_base          = 0x800; // sink area 0x800–0xBFF
constexpr int sink_count         = 1024;
constexpr int address_space      = 4096;  // what i and j can address
constexpr int io_base            = 0x040; // read-only inputs
constexpr int io_count           = 32;
constexpr int constant_base      = 0x001; // the constant pool
constexpr int constant_count     = 63;
constexpr int direct_reach       = 512;  // direct operands: 0–511
constexpr int max_program_length = 1472; // instructions per pass
constexpr int write_window       = 48;   // queued writes per pass
constexpr int cycles_per_pass    = 1536; // two samples at 73.728 MHz
constexpr int index_delay        = 3;    // IDX delay slots

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

// ---- opcodes --------------------------------------------------------------

enum class Opcode : uint8_t {
    nop    = 0,
    loop   = 1,
    macw   = 2,
    interp = 3,
    acc    = 4,
    add3   = 5,
    sel    = 6,
    cmp    = 7,
    min    = 8,
    max    = 9,
    andxor = 10,
    shift  = 11,
    mac    = 12,
    abs    = 13,
    skip   = 14,
    idx    = 15,
};

// The a field: which value is the A operand.
enum class ASelect : uint8_t {
    zero        = 0,
    result      = 1, // A = R
    accumulator = 2, // A = acc
    wide        = 3, // A = R, and the instruction is wide
};

// SKIP conditions (X field).
enum class Condition : uint8_t {
    always   = 0,
    negative = 1,
    positive = 2, // N clear
    zero     = 3,
    nonzero  = 4,
    overflow = 5,
};

std::string_view mnemonic(Opcode op);

// Whether an opcode has a wide form (a = 3, `.w` in assembly).
bool has_wide_form(Opcode op);

// ---- operands -------------------------------------------------------------
//
// A 10-bit operand field: 0aaaaaaaaa direct, 10oooooooo i + o,
// 11oooooooo j + o.

enum class IndexRegister : uint8_t { i = 0, j = 1 };

struct Operand {
    enum class Mode : uint8_t { direct, indexed } mode = Mode::direct;
    IndexRegister index                                = IndexRegister::i;
    int value = 0; // the address (direct) or the offset (indexed)

    static Operand direct(int address) {
        return {Mode::direct, IndexRegister::i, address};
    }
    static Operand indexed(IndexRegister index, int offset) {
        return {Mode::indexed, index, offset};
    }

    uint16_t encode() const;
    static Operand decode(uint16_t field);
    bool operator==(const Operand &) const = default;
};

// ---- the instruction word -------------------------------------------------
//
// [35:32] op  [31:30] a  [29:20] R  [19:10] X  [9:0] Y

struct Instruction {
    Opcode op  = Opcode::nop;
    ASelect a  = ASelect::zero;
    uint16_t r = 0; // raw fields: an operand or an immediate,
    uint16_t x = 0; // by opcode
    uint16_t y = 0;

    uint64_t encode() const;
    static Instruction decode(uint64_t word);
    bool operator==(const Instruction &) const = default;
};

} // namespace csp
