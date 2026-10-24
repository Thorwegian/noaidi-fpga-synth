// assembler.hpp — the CSP assembler
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Turns CSP assembly (docs/csp2_isa.md; the syntax below) into an image —
// the instruction rows and the decode ROM — through csp::ProgramBuilder,
// which schedules and checks. Names, blocks and labels are for
// the reader; the chip sees rows.
//
//   label:  MNEMONIC operand, operand, ...   ; comment
//
//   operands   r37, 0x25        a register, direct (0–1023)
//              NAME             a .reg, .wide or .const name
//              [i+NAME], [i+3]  i plus an offset; [i] is offset 0
//              =0.5, =#3        an immediate: a Q4.14 value, or a raw integer
//   directives .equ NAME, value           a name for a number
//              .reg NAME, address          a register
//              .wide NAME, address         a wide register (even)
//              .const NAME, value          a named immediate
//              .block NAME … .field NAME, words … .end   a block's layout
//              .org address                the next instruction's row

#pragma once

#include <map>
#include <string>
#include <string_view>
#include <vector>

#include "csp/csp.hpp"
#include "csp/program_builder.hpp"

namespace csp {

struct Diagnostic {
    int line;
    bool error;
    std::string message;
};

struct Program {
    Image image;
    bool ok    = false;
    int cycles = 0; // the pass's cycles as scheduled
    std::vector<Diagnostic> diagnostics;
    std::map<std::string, int> symbols; // every name and its value
    std::vector<int> source_lines;      // each row's source line, 0 for a wait
};

Program assemble(std::string_view source);

} // namespace csp
