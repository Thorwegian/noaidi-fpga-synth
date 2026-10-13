// program_builder.hpp — CSP programs as machine code, built in C++
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The firmware writes CSP programs with this, one call per instruction,
// and the macro assembler in tools/csp is a text front end to it. Each
// call checks its operands as it emits; check() then looks at the
// program as a whole: loop nesting and ends, SKIP
// ranges and the program's length (docs/csp_manual.md sections 5 and 7).
//
// Built without exceptions or RTTI, as the firmware is.

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "csp.hpp"

namespace csp {

// Something wrong with the program, at an instruction's position.
struct BuildIssue {
    size_t at  = 0;
    bool error = true; // false: a warning
    std::string message;
};

class ProgramBuilder {
public:
    // Every emitting call returns the instruction's position.

    size_t nop();

    // A is ASelect::zero, ::result (A = R) or ::accumulator.
    size_t mac(Operand r, ASelect a, Operand x, Operand y);
    size_t macw(Operand r, ASelect a, Operand x, Operand y);
    size_t interp(Operand r, ASelect a, Operand x, Operand y);
    size_t add3(Operand r, ASelect a, Operand x, Operand y);
    size_t andxor(Operand r, ASelect a, Operand x, Operand y);
    size_t shift(Operand r, ASelect a, Operand y);

    // The wide forms: R, A (= R) and Y are wide pairs, X is a word.
    size_t mac_wide(Operand r, Operand x, Operand y);
    size_t macw_wide(Operand r, Operand x, Operand y);
    size_t interp_wide(Operand r, Operand x, Operand y);
    size_t add3_wide(Operand r, Operand x, Operand y);
    size_t shift_wide(Operand r, Operand y);

    // A is ASelect::zero or ::accumulator.
    size_t acc(ASelect a, Operand x, Operand y);

    size_t sel(Operand r, Operand x, Operand y);
    size_t cmp(Operand r, Operand x, Operand y);
    size_t min(Operand r, Operand x, Operand y);
    size_t max(Operand r, Operand x, Operand y);
    size_t abs(Operand r, Operand x);
    size_t idx(IndexRegister which, Operand x, Operand y);

    // A loop over `length` instructions, or an open one whose end is set
    // later with close_loop(): at the current position, or at a given one
    // (a forward label in the assembler).
    size_t loop(IndexRegister which, size_t length, Operand count,
                Operand stride);
    size_t open_loop(IndexRegister which, Operand count, Operand stride);
    void close_loop(size_t at);
    void close_loop(size_t at, size_t end);

    // The same for SKIP: `count` instructions, or up to an end set later.
    size_t skip(Condition condition, size_t count);
    size_t open_skip(Condition condition);
    void close_skip(size_t at);
    void close_skip(size_t at, size_t end);

    // NOPs up to `position`.
    void pad_to(size_t position);

    size_t size() const {
        return words_.size();
    }
    const std::vector<uint64_t> &words() const {
        return words_;
    }

    // The issues found while emitting, plus the whole-program checks.
    std::vector<BuildIssue> check() const;

private:
    struct LoopRecord {
        size_t at;
        size_t end; // one past the body; 0 while open
        IndexRegister index;
    };
    struct SkipRecord {
        size_t at;
        size_t end; // one past the last skipped instruction; 0 while open
    };

    size_t emit(const Instruction &instruction);
    size_t arithmetic(Opcode op, Operand r, ASelect a, Operand x, Operand y);
    size_t wide(Opcode op, Operand r, Operand x, Operand y);
    uint16_t field(Operand operand);
    void issue(std::string message, bool error = true);

    std::vector<uint64_t> words_;
    std::vector<LoopRecord> loops_;
    std::vector<SkipRecord> skips_;
    std::vector<BuildIssue> issues_;
};

} // namespace csp
