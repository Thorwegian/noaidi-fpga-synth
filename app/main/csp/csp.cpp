// csp.cpp — the CSP's instruction word and operands (see csp.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "csp.hpp"

#include <array>

namespace csp {

std::string_view mnemonic(Opcode op) {
    static constexpr std::array<std::string_view, 16> names = {
            "NOP", "LOOP", "MACW",   "INTERP", "ACC", "ADD3", "SEL",  "CMP",
            "MIN", "MAX",  "ANDXOR", "SHIFT",  "MAC", "ABS",  "SKIP", "IDX"};
    return names[static_cast<size_t>(op)];
}

bool has_wide_form(Opcode op) {
    switch (op) {
    case Opcode::mac:
    case Opcode::macw:
    case Opcode::interp:
    case Opcode::add3:
    case Opcode::shift:
        return true;
    default:
        return false;
    }
}

uint16_t Operand::encode() const {
    if (mode == Mode::direct) {
        return static_cast<uint16_t>(value & 0x1FF);
    }
    const uint16_t select = index == IndexRegister::j ? 0x100 : 0;
    return static_cast<uint16_t>(0x200 | select | (value & 0xFF));
}

Operand Operand::decode(uint16_t field) {
    if ((field & 0x200) == 0) {
        return direct(field & 0x1FF);
    }
    const IndexRegister index =
            (field & 0x100) ? IndexRegister::j : IndexRegister::i;
    return indexed(index, field & 0xFF);
}

uint64_t Instruction::encode() const {
    return (uint64_t{static_cast<uint8_t>(op)} << 32)
           | (uint64_t{static_cast<uint8_t>(a)} << 30)
           | (uint64_t{r & 0x3FFu} << 20) | (uint64_t{x & 0x3FFu} << 10)
           | uint64_t{y & 0x3FFu};
}

Instruction Instruction::decode(uint64_t word) {
    Instruction instruction;
    instruction.op = static_cast<Opcode>((word >> 32) & 0xF);
    instruction.a  = static_cast<ASelect>((word >> 30) & 0x3);
    instruction.r  = static_cast<uint16_t>((word >> 20) & 0x3FF);
    instruction.x  = static_cast<uint16_t>((word >> 10) & 0x3FF);
    instruction.y  = static_cast<uint16_t>(word & 0x3FF);
    return instruction;
}

} // namespace csp
