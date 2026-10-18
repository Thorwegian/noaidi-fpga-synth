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
    case Op::interp: return "INTERP";
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
           | (static_cast<uint32_t>(a_source) << 10) | (y_wide ? 1u << 8 : 0)
           | (static_cast<uint32_t>(cond) << 6) | (barrier ? 1u << 5 : 0) | (wrap ? 1u << 3 : 0)
           | (sub & 7u);
}

Control Control::decode(uint32_t row) {
    Control control;
    control.unit     = static_cast<Unit>((row >> 15) & 7);
    control.writes   = static_cast<Writes>((row >> 12) & 7);
    control.a_source = static_cast<ASource>((row >> 10) & 3);
    control.y_wide   = (row >> 8) & 1;
    control.cond     = static_cast<ConditionKind>((row >> 6) & 3);
    control.barrier  = (row >> 5) & 1;
    control.wrap     = (row >> 3) & 1;
    control.sub      = row & 7;
    return control;
}

Control control_of(Op op, bool wide, ASource a_source) {
    Control c;
    const Writes result = wide ? Writes::pair : Writes::word;
    switch (op) {
    case Op::nop:
        break;
    case Op::mac:
    case Op::macw:
        c = {Unit::multiply_add, result, a_source, wide, ConditionKind::flags, false, op == Op::macw,
             static_cast<uint8_t>(MultiplyAddOp::mac)};
        break;
    case Op::acc:
        c = {Unit::multiply_add, Writes::accumulator, a_source, false, ConditionKind::none, false, false,
             static_cast<uint8_t>(MultiplyAddOp::mac)};
        break;
    case Op::interp:
        c = {Unit::multiply_add, result, a_source, wide, ConditionKind::flags, false, false,
             static_cast<uint8_t>(MultiplyAddOp::interp)};
        break;
    case Op::add3:
        c = {Unit::multiply_add, result, a_source, wide, ConditionKind::flags, false, false,
             static_cast<uint8_t>(MultiplyAddOp::add3)};
        break;
    case Op::cmp:
        c = {Unit::multiply_add, Writes::word, ASource::zero, false, ConditionKind::flags, false, false,
             static_cast<uint8_t>(MultiplyAddOp::cmp)};
        break;
    case Op::abs:
        c = {Unit::multiply_add, Writes::word, ASource::zero, false, ConditionKind::flags, false, false,
             static_cast<uint8_t>(MultiplyAddOp::abs)};
        break;
    case Op::min:
        c = {Unit::logic, Writes::word, ASource::zero, false, ConditionKind::flags, false, false,
             static_cast<uint8_t>(LogicOp::min)};
        break;
    case Op::max:
        c = {Unit::logic, Writes::word, ASource::zero, false, ConditionKind::flags, false, false,
             static_cast<uint8_t>(LogicOp::max)};
        break;
    case Op::sel:
        c = {Unit::logic, Writes::word, ASource::zero, false, ConditionKind::select, false, false,
             static_cast<uint8_t>(LogicOp::sel)};
        break;
    case Op::andxor:
        c = {Unit::logic, Writes::word, a_source, false, ConditionKind::flags, false, false,
             static_cast<uint8_t>(LogicOp::andxor)};
        break;
    case Op::shift:
        c = {Unit::shift, result, a_source, false, ConditionKind::flags, false, false, 0};
        break;
    case Op::loop:
    case Op::vloop:
        // the index register is the sub-operation's low bit, set by the caller
        c = {Unit::loop, Writes::nothing, ASource::zero, false, ConditionKind::none, true, false,
             static_cast<uint8_t>(op == Op::vloop ? LoopOp::vector_i : LoopOp::scalar_i)};
        break;
    case Op::skip:
        c = {Unit::skip, Writes::nothing, ASource::zero, false, ConditionKind::skip, false, false, 0};
        break;
    case Op::idx:
        c = {Unit::index, Writes::index_i, ASource::zero, false, ConditionKind::none, true, false, 0};
        break;
    }
    return c;
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
