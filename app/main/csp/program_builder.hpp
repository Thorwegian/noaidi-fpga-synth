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
// when their addresses are equal. An indexed operand names a known address
// when its index register was set from an immediate alone (IDX with a
// register of 0), and one of a list of addresses when its IDX said which
// the index may hold (IndexTargets): the places a pointer can point. It is
// then scheduled against those words alone, which is what lets straight-line
// code read through a pointer right behind a write to another word.
// Otherwise it may name anything, so it waits for every earlier write —
// inside a vector loop too, where the base steps per element, so two indexed
// operands with different offsets are still kept ceil(latency / elements)
// rows apart, which costs nothing at sixteen elements.
//
// Built without exceptions or RTTI, as the firmware is.

#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
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

// The addresses an index register may hold after an IDX: a list the builder
// keeps (ProgramBuilder::targets), shared by every IDX that names it.
struct IndexTargets {
    size_t first = 0; // in the builder's list of addresses
    size_t count = 0; // none: nothing is said of the index
};

// An operand as the program names it: a register, an indexed register, or
// an immediate value.
struct Source {
    Operand operand;
    int32_t immediate = 0; // when operand.mode is immediate

    static Source reg(Operand operand) {
        return {operand, 0};
    }
    static Source imm(int32_t raw) {
        return {Operand::immediate(), raw};
    }
};

class ProgramBuilder {
public:
    // Every emitting call returns the instruction's position (before
    // scheduling; build() reports the final one).

    size_t nop();

    // A is ASource::zero or ::result (A = R). With `wide`, R
    // and Y are pairs and X a word; A is then R (in place).
    size_t mac(Operand r, ASource a, Source x, Source y, bool wide = false);
    size_t macw(Operand r, ASource a, Source x, Source y, bool wide = false);
    size_t add3(Operand r, ASource a, Source x, Source y, bool wide = false);
    size_t andxor(Operand r, ASource a, Source x, Source y);
    size_t shift(Operand r, ASource a, Source y, bool wide = false);


    size_t sel(Operand r, Condition cond, Source x, Source y);
    // R = X − Y, and the flags of the difference: what a SEL chooses by.
    size_t cmp(Operand r, Source x, Source y);
    // R = X − Y, the flags left as they are.
    size_t sub(Operand r, Source x, Source y);
    size_t min(Operand r, Source x, Source y);
    size_t max(Operand r, Source x, Source y);
    size_t abs(Operand r, Source x);
    // i or j = X + Y, raw.
    size_t idx(IndexRegister which, Source x, Source y);
    // The same, of a sum that is one of `targets`: a pointer. An operand
    // through the index then names each of those addresses with its offset
    // beside it, until the register is set again by an IDX or a loop. The
    // list is the caller's promise: the reference model reports the early
    // read that a pointer outside it can cause.
    size_t idx(IndexRegister which, Source x, Source y, IndexTargets targets);
    // A list of addresses for IDXs to name.
    IndexTargets targets(std::span<const int> addresses);

    // An open loop, whose end is set later with close_loop(): at the current
    // position, or at a given one (a forward label in the assembler). The
    // count and the stride are immediates. A vector loop runs its body
    // instruction by instruction across its elements, in rounds of sixteen.
    size_t open_loop(IndexRegister which, int count, int stride,
                     bool vector = false);
    void close_loop(size_t at);
    void close_loop(size_t at, size_t end);

    // The same for SKIP: `count` instructions, or up to an end set later.

    size_t size() const {
        return instructions_.size();
    }

    // Schedule and encode: the image, and the issues found while emitting
    // plus the whole-program checks. A program with an error builds an
    // empty image. The result is filled in where the caller keeps it: an
    // image is larger than a task's stack on the chip, so the firmware's is
    // a static object. The host's tools take it by value.
    struct Built {
        Image image;
        std::vector<BuildIssue> issues;
        std::vector<size_t>
                position; // each emitted instruction's row in the image
        int cycles = 0;   // the pass's cycles, the waits included
        bool ok    = true;
    };
    void build(Built &built) const;
    Built build() const;

private:
    struct Entry {
        Op op            = Op::nop;
        bool wide        = false;
        ASource a_source = ASource::zero;
        Condition cond   = Condition::always;
        Operand r, x, y;
        int32_t immediate   = 0; // x's or y's, or the loop's stride
        int count           = 0; // a loop's count
        IndexRegister which = IndexRegister::i;
        size_t end          = 0; // a loop's end, one past; 0 while open
        bool open           = false;
        IndexTargets targets; // an IDX's: what its index may hold
    };

    size_t emit(Entry entry);
    size_t arithmetic(Op op, Operand r, ASource a, Source x, Source y,
                      bool wide);
    void check_operand(const Operand &operand, bool wide, bool result);
    void issue(std::string message, bool error = true);

    std::vector<Entry> instructions_;
    std::vector<int> target_addresses_; // every IndexTargets' list, end to end
    mutable std::vector<BuildIssue> issues_;
};

} // namespace csp
