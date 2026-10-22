// csp.cpp — the CSP's word, operands and control words (see csp.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "csp.hpp"

namespace csp {

std::string_view mnemonic(Op op) {
    switch (op) {
    case Op::nop: return "NOP";
    case Op::mac: return "MAC";
    case Op::macw: return "MACW";
    case Op::acc: return "ACC";
    case Op::add3: return "ADD3";
    case Op::cmp: return "CMP";
    case Op::abs: return "ABS";
    case Op::min: return "MIN";
    case Op::max: return "MAX";
    case Op::sel: return "SEL";
    case Op::andxor: return "ANDXOR";
    case Op::shift: return "SHIFT";
    case Op::loop: return "LOOP";
    case Op::vloop: return "LOOP.v";
    case Op::skip: return "SKIP";
    case Op::idx: return "IDX";
    }
    return "?";
}

// ---- operands -------------------------------------------------------------

uint16_t Operand::encode() const {
    return static_cast<uint16_t>((static_cast<uint16_t>(mode) << 10) | (value & 0x3FF));
}

Operand Operand::decode(uint16_t field) {
    return {static_cast<Mode>((field >> 10) & 3), field & 0x3FF};
}

// ---- control words --------------------------------------------------------

uint32_t Control::encode() const {
    return (static_cast<uint32_t>(unit) << 15) | (static_cast<uint32_t>(writes) << 12)
           | (static_cast<uint32_t>(a_source) << 10) | (reads_x ? 1u << 9 : 0) | (y_wide ? 1u << 8 : 0)
           | (static_cast<uint32_t>(cond) << 6) | (reads_y ? 1u << 5 : 0) | (wrap ? 1u << 3 : 0)
           | (sub & 7u);
}

Control Control::decode(uint32_t row) {
    Control control;
    control.unit     = static_cast<Unit>((row >> 15) & 7);
    control.writes   = static_cast<Writes>((row >> 12) & 7);
    control.a_source = static_cast<ASource>((row >> 10) & 3);
    control.reads_x  = (row >> 9) & 1;
    control.y_wide   = (row >> 8) & 1;
    control.cond     = static_cast<ConditionKind>((row >> 6) & 3);
    control.reads_y  = (row >> 5) & 1;
    control.wrap     = (row >> 3) & 1;
    control.sub      = row & 7;
    return control;
}

Control control_of(Op op, bool wide, ASource a_source) {
    // Control fields in order: unit, writes, a_source, reads_x, y_wide, cond, reads_y, wrap, sub.
    const Writes result = wide ? Writes::pair : Writes::word;
    switch (op) {
    case Op::nop:
        return {};
    case Op::mac:
    case Op::macw:
        return {Unit::multiply_add, result, a_source, true, wide, ConditionKind::flags, true, op == Op::macw,
                static_cast<uint8_t>(MultiplyAddOp::mac)};
    case Op::acc:
        return {Unit::multiply_add, Writes::accumulator, a_source, true, false, ConditionKind::none, true, false,
                static_cast<uint8_t>(MultiplyAddOp::mac)};
    case Op::add3:
        return {Unit::multiply_add, result, a_source, true, wide, ConditionKind::flags, true, false,
                static_cast<uint8_t>(MultiplyAddOp::add3)};
    case Op::cmp:
        return {Unit::multiply_add, Writes::word, ASource::zero, true, false, ConditionKind::flags, true, false,
                static_cast<uint8_t>(MultiplyAddOp::cmp)};
    case Op::abs:
        return {Unit::multiply_add, Writes::word, ASource::zero, true, false, ConditionKind::flags, false, false,
                static_cast<uint8_t>(MultiplyAddOp::abs)};
    case Op::min:
        return {Unit::logic, Writes::word, ASource::zero, true, false, ConditionKind::flags, true, false,
                static_cast<uint8_t>(LogicOp::min)};
    case Op::max:
        return {Unit::logic, Writes::word, ASource::zero, true, false, ConditionKind::flags, true, false,
                static_cast<uint8_t>(LogicOp::max)};
    case Op::sel:
        return {Unit::logic, Writes::word, ASource::zero, true, false, ConditionKind::select, true, false,
                static_cast<uint8_t>(LogicOp::sel)};
    case Op::andxor:
        return {Unit::logic, Writes::word, a_source, true, false, ConditionKind::flags, true, false,
                static_cast<uint8_t>(LogicOp::andxor)};
    case Op::shift:
        // the count is Y; X is not read
        return {Unit::shift, result, a_source, false, false, ConditionKind::flags, true, false, 0};
    case Op::loop:
    case Op::vloop:
        // the index register is the sub-operation's low bit, set by the caller; the
        // count, the stride and the end are in the word, not read from DMEM
        return {Unit::loop, Writes::nothing, ASource::zero, false, false, ConditionKind::none, false, false,
                static_cast<uint8_t>(op == Op::vloop ? LoopOp::vector_i : LoopOp::scalar_i)};
    case Op::skip:
        return {Unit::skip, Writes::nothing, ASource::zero, false, false, ConditionKind::skip, false, false, 0};
    case Op::idx:
        return {Unit::index, Writes::index_i, ASource::zero, true, false, ConditionKind::none, true, false, 0};
    }
    return {};
}

// ---- the word -------------------------------------------------------------

Row Word::encode() const {
    const uint64_t r_bits = r.encode(), x_bits = x.encode(), y_bits = y.encode();
    Row row;
    // [71:64] op, [63:60] cond, [59:48] r, [47:36] x: the high dword's 36 bits are 71:36
    row.high = (static_cast<uint64_t>(op & 0xFF) << 28) | (static_cast<uint64_t>(cond & 0xF) << 24) | (r_bits << 12) | x_bits;
    // [35:24] y, [23:0] imm
    row.low = (y_bits << 24) | (imm & 0xFFFFFF);
    return row;
}

Word Word::decode(const Row &row) {
    Word word;
    word.op   = static_cast<uint16_t>((row.high >> 28) & 0xFF);
    word.cond = static_cast<uint8_t>((row.high >> 24) & 0xF);
    word.r    = Operand::decode(static_cast<uint16_t>((row.high >> 12) & 0xFFF));
    word.x    = Operand::decode(static_cast<uint16_t>(row.high & 0xFFF));
    word.y    = Operand::decode(static_cast<uint16_t>((row.low >> 24) & 0xFFF));
    word.imm  = static_cast<uint32_t>(row.low & 0xFFFFFF);
    return word;
}

} // namespace csp
