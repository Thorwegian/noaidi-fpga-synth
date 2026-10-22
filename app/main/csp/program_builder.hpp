// program_builder.hpp — CSP programs as machine code, built and scheduled
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The firmware generates CSP programs with this, one call per instruction,
// and the macro assembler in tools/csp is a text front end to it. Each
// call checks its operands as it emits. build() then does what the chip
// does not (docs/csp2_isa.md sections 1 and 8): it allots the decode ROM's
// rows, places every instruction so that what it reads has been written —
// inserting NOPs where the program's order does not leave the latency —
// counts the pass's cycles, and refuses a program that does not fit. The
// result is an Image: the rows and the ROM, as the firmware loads them.
//
// What "may alias" means to the scheduler: two direct operands conflict
// when their addresses are equal; an indexed operand names a known
// address when its index register was set from an immediate alone (IDX
// with a register of 0), and otherwise may name anything, so it waits for
// every earlier write — inside a vector loop too, where the base steps per
// element, so two indexed operands with different offsets are still kept
// ceil(latency / elements) rows apart. Knowing more (the regions the first
// draft had) was measured at three cycles in 1465 on the control program,
// and the vector rule costs nothing at sixteen elements; a finer rule
// (offsets through one index register conflict only when equal) is #236's
// if its loops need it.
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

// An immediate in x or y: the word's imm field as a Q4.14 value, raw.
struct Immediate {
    int32_t raw = 0;
};

// An operand as the program names it: a register, an indexed register, or
// an immediate value.
struct Source {
    Operand operand;
    int32_t immediate = 0; // when operand.mode is immediate

    static Source reg(Operand operand) { return {operand, 0}; }
    static Source imm(int32_t raw) { return {Operand::immediate(), raw}; }
};

class ProgramBuilder {
public:
    // Every emitting call returns the instruction's position (before
    // scheduling; build() reports the final one).

    size_t nop();

    // A is ASource::zero, ::result (A = R) or ::accumulator. With `wide`, R
    // and Y are pairs and X a word; A is then R (in place).
    size_t mac(Operand r, ASource a, Source x, Source y, bool wide = false);
    size_t macw(Operand r, ASource a, Source x, Source y, bool wide = false);
    size_t add3(Operand r, ASource a, Source x, Source y, bool wide = false);
    size_t andxor(Operand r, ASource a, Source x, Source y);
    size_t shift(Operand r, ASource a, Source y, bool wide = false);

    // A is ASource::zero or ::accumulator.
    size_t acc(ASource a, Source x, Source y);

    size_t sel(Operand r, Condition cond, Source x, Source y);
    size_t cmp(Operand r, Source x, Source y);
    size_t min(Operand r, Source x, Source y);
    size_t max(Operand r, Source x, Source y);
    size_t abs(Operand r, Source x);
    // i or j = X + Y, raw.
    size_t idx(IndexRegister which, Source x, Source y);

    // A loop over `length` instructions, or an open one whose end is set
    // later with close_loop(): at the current position, or at a given one
    // (a forward label in the assembler). The count and the stride are
    // immediates. A vector loop runs its body instruction by instruction
    // across its elements, in rounds of sixteen.
    size_t loop(IndexRegister which, size_t length, int count, int stride, bool vector = false);
    size_t open_loop(IndexRegister which, int count, int stride, bool vector = false);
    void close_loop(size_t at);
    void close_loop(size_t at, size_t end);

    // The same for SKIP: `count` instructions, or up to an end set later.
    size_t skip(Condition cond, size_t count);
    size_t open_skip(Condition cond);
    void close_skip(size_t at);
    void close_skip(size_t at, size_t end);

    size_t size() const { return instructions_.size(); }

    // Schedule and encode: the image, and the issues found while emitting
    // plus the whole-program checks. A program with an error builds an
    // empty image.
    struct Built {
        Image image;
        std::vector<BuildIssue> issues;
        std::vector<size_t> position; // each emitted instruction's row in the image
        int cycles = 0;               // the pass's cycles, the waits included
        bool ok    = true;
    };
    Built build() const;

private:
    struct Entry {
        Op op = Op::nop;
        bool wide = false;
        ASource a_source = ASource::zero;
        Condition cond = Condition::always;
        Operand r, x, y;
        int32_t immediate = 0;    // x's or y's, or the loop's stride
        int count = 0;            // a loop's count
        IndexRegister which = IndexRegister::i;
        size_t end = 0;           // a loop's or skip's end, one past; 0 while open
        bool open = false;
    };

    size_t emit(Entry entry);
    size_t arithmetic(Op op, Operand r, ASource a, Source x, Source y, bool wide);
    void check_operand(const Operand &operand, bool wide, bool result);
    void issue(std::string message, bool error = true);

    std::vector<Entry> instructions_;
    mutable std::vector<BuildIssue> issues_;
};

} // namespace csp
