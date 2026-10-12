// assembler.hpp — the CSP assembler
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Turns CSP assembly (docs/csp_manual.md section 6) into instruction
// words plus the constant registers the firmware writes at start-up,
// and checks what the hardware cannot: IDX delay slots, loop nesting,
// SKIP ranges, direct operands beyond reach and `.w` where an
// instruction has no wide form.

#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace csp {

struct Diagnostic {
    int line   = 0;
    bool error = true; // false: a warning
    std::string message;
};

// A constant register and its value, for the firmware to write once.
struct ConstantWrite {
    int address = 0;
    int32_t raw = 0;
};

struct Program {
    std::vector<uint64_t> words;   // the instructions, 36 bits each
    std::vector<int> source_lines; // the source line of each word (0: padding)
    std::vector<ConstantWrite> constants;
    std::map<std::string, int> symbols; // every name and its value
    std::vector<Diagnostic> diagnostics;

    bool ok() const;
};

Program assemble(std::string_view source);

} // namespace csp
