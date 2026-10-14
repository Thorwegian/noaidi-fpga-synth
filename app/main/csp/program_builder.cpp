// program_builder.cpp — CSP programs as machine code (see program_builder.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "program_builder.hpp"

namespace csp {

namespace {

constexpr size_t max_length = 1023; // a LOOP's or SKIP's 10-bit count

} // namespace

// ---- emitting -----------------------------------------------------------------

void ProgramBuilder::issue(std::string message, bool error) {
    issues_.push_back({words_.size(), error, std::move(message)});
}

uint16_t ProgramBuilder::field(Operand operand) {
    if (operand.mode == Operand::Mode::direct) {
        if (operand.value < 0 || operand.value >= direct_reach) {
            issue("register " + std::to_string(operand.value)
                  + " is beyond direct reach (0-511): use i or j");
        }
    } else if (operand.value < 0 || operand.value > 255) {
        issue("index offset " + std::to_string(operand.value)
              + " outside 0-255");
    }
    return operand.encode();
}

size_t ProgramBuilder::emit(const Instruction &instruction) {
    words_.push_back(instruction.encode());
    return words_.size() - 1;
}

size_t ProgramBuilder::arithmetic(Opcode op, Operand r, ASelect a, Operand x,
                                  Operand y) {
    if (a == ASelect::wide) {
        issue(std::string(mnemonic(op)) + ": use the wide form for a = wide");
    }
    return emit({op, a, field(r), field(x), field(y)});
}

size_t ProgramBuilder::wide(Opcode op, Operand r, Operand x, Operand y) {
    return emit({op, ASelect::wide, field(r), field(x), field(y)});
}

size_t ProgramBuilder::nop() {
    return emit({});
}

size_t ProgramBuilder::mac(Operand r, ASelect a, Operand x, Operand y) {
    return arithmetic(Opcode::mac, r, a, x, y);
}

size_t ProgramBuilder::macw(Operand r, ASelect a, Operand x, Operand y) {
    return arithmetic(Opcode::macw, r, a, x, y);
}

size_t ProgramBuilder::interp(Operand r, ASelect a, Operand x, Operand y) {
    return arithmetic(Opcode::interp, r, a, x, y);
}

size_t ProgramBuilder::add3(Operand r, ASelect a, Operand x, Operand y) {
    return arithmetic(Opcode::add3, r, a, x, y);
}

size_t ProgramBuilder::andxor(Operand r, ASelect a, Operand x, Operand y) {
    return arithmetic(Opcode::andxor, r, a, x, y);
}

size_t ProgramBuilder::shift(Operand r, ASelect a, Operand y) {
    if (a == ASelect::wide) {
        issue("SHIFT: use the wide form for a = wide");
    }
    return emit({Opcode::shift, a, field(r), 0, field(y)});
}

size_t ProgramBuilder::mac_wide(Operand r, Operand x, Operand y) {
    return wide(Opcode::mac, r, x, y);
}

size_t ProgramBuilder::macw_wide(Operand r, Operand x, Operand y) {
    return wide(Opcode::macw, r, x, y);
}

size_t ProgramBuilder::interp_wide(Operand r, Operand x, Operand y) {
    return wide(Opcode::interp, r, x, y);
}

size_t ProgramBuilder::add3_wide(Operand r, Operand x, Operand y) {
    return wide(Opcode::add3, r, x, y);
}

size_t ProgramBuilder::shift_wide(Operand r, Operand y) {
    return emit({Opcode::shift, ASelect::wide, field(r), 0, field(y)});
}

size_t ProgramBuilder::acc(ASelect a, Operand x, Operand y) {
    if (a != ASelect::zero && a != ASelect::accumulator) {
        issue("ACC: A must be zero or the accumulator");
    }
    return emit({Opcode::acc, a, 0, field(x), field(y)});
}

size_t ProgramBuilder::sel(Operand r, Operand x, Operand y) {
    return emit({Opcode::sel, ASelect::zero, field(r), field(x), field(y)});
}

size_t ProgramBuilder::cmp(Operand r, Operand x, Operand y) {
    return emit({Opcode::cmp, ASelect::zero, field(r), field(x), field(y)});
}

size_t ProgramBuilder::min(Operand r, Operand x, Operand y) {
    return emit({Opcode::min, ASelect::zero, field(r), field(x), field(y)});
}

size_t ProgramBuilder::max(Operand r, Operand x, Operand y) {
    return emit({Opcode::max, ASelect::zero, field(r), field(x), field(y)});
}

size_t ProgramBuilder::abs(Operand r, Operand x) {
    return emit({Opcode::abs, ASelect::zero, field(r), field(x), 0});
}

size_t ProgramBuilder::idx(IndexRegister which, Operand x, Operand y) {
    return emit({Opcode::idx, ASelect::zero, static_cast<uint16_t>(which),
                 field(x), field(y)});
}

// ---- loops and skips ------------------------------------------------------------

size_t ProgramBuilder::open_loop(IndexRegister which, Operand count,
                                 Operand stride, bool vector) {
    // a bit 0 selects the index register, bit 1 a vector loop; the length
    // is set on closing
    const auto a    = static_cast<ASelect>((vector ? 2 : 0)
                                           | (which == IndexRegister::j ? 1 : 0));
    const size_t at = emit({Opcode::loop, a, 0, field(count), field(stride)});
    loops_.push_back({at, 0, which, vector});
    return at;
}

size_t ProgramBuilder::loop(IndexRegister which, size_t length, Operand count,
                            Operand stride, bool vector) {
    const size_t at = open_loop(which, count, stride, vector);
    close_loop(at, at + 1 + length);
    return at;
}

void ProgramBuilder::close_loop(size_t at) {
    close_loop(at, words_.size());
}

void ProgramBuilder::close_loop(size_t at, size_t end) {
    for (LoopRecord &loop : loops_) {
        if (loop.at != at) {
            continue;
        }
        const size_t length = end > at + 1 ? end - (at + 1) : 0;
        if (length < 1 || length > max_length) {
            issues_.push_back({at, true, "LOOP length outside 1-1023"});
            return;
        }
        loop.end                = end;
        Instruction instruction = Instruction::decode(words_[at]);
        instruction.r           = static_cast<uint16_t>(length);
        words_[at]              = instruction.encode();
        return;
    }
    issues_.push_back({at, true, "close_loop: no LOOP at this position"});
}

size_t ProgramBuilder::open_skip(Condition condition) {
    const size_t at = emit({Opcode::skip, ASelect::zero, 0,
                            static_cast<uint16_t>(condition), 0});
    skips_.push_back({at, 0});
    return at;
}

size_t ProgramBuilder::skip(Condition condition, size_t count) {
    const size_t at = open_skip(condition);
    close_skip(at, at + 1 + count);
    return at;
}

void ProgramBuilder::close_skip(size_t at) {
    close_skip(at, words_.size());
}

void ProgramBuilder::close_skip(size_t at, size_t end) {
    for (SkipRecord &skip : skips_) {
        if (skip.at != at) {
            continue;
        }
        const size_t count = end > at + 1 ? end - (at + 1) : 0;
        if (count < 1 || count > max_length) {
            issues_.push_back({at, true, "SKIP count outside 1-1023"});
            return;
        }
        skip.end                = end;
        Instruction instruction = Instruction::decode(words_[at]);
        instruction.y           = static_cast<uint16_t>(count);
        words_[at]              = instruction.encode();
        return;
    }
    issues_.push_back({at, true, "close_skip: no SKIP at this position"});
}

void ProgramBuilder::pad_to(size_t position) {
    while (words_.size() < position) {
        nop();
    }
}

// ---- whole-program checks ---------------------------------------------------------

// What a vector loop's body may not hold: what has one copy for all
// iterations (a loop, the skip counter, the accumulator) or would move the
// loop's own index register.
void ProgramBuilder::check_vector_body(const LoopRecord &loop,
                                       std::vector<BuildIssue> &issues) const {
    for (size_t at = loop.at + 1; at < loop.end; ++at) {
        const Instruction instruction = Instruction::decode(words_[at]);
        const Opcode op               = instruction.op;
        const bool reads_accumulator =
                instruction.a == ASelect::accumulator
                && (op == Opcode::mac || op == Opcode::macw
                    || op == Opcode::interp || op == Opcode::add3
                    || op == Opcode::andxor || op == Opcode::shift);
        const bool moves_loop_index =
                op == Opcode::idx
                && (instruction.r & 1) == static_cast<uint16_t>(loop.index);
        if (op == Opcode::loop || op == Opcode::skip || op == Opcode::acc
            || reads_accumulator) {
            issues.push_back({at, true,
                              "LOOP, SKIP, ACC and acc are not allowed in a "
                              "vector loop's body"});
        } else if (moves_loop_index) {
            issues.push_back(
                    {at, true, "IDX on a vector loop's own index register"});
        }
    }
}

std::vector<BuildIssue> ProgramBuilder::check() const {
    std::vector<BuildIssue> issues = issues_;

    if (words_.size() > max_program_length) {
        issues.push_back({max_program_length, true,
                          "program is " + std::to_string(words_.size())
                                  + " instructions; a pass holds "
                                  + std::to_string(max_program_length)});
    }

    // Loops: closed, inside the program, nested at most one level, on
    // different index registers, ending at or before their outer loop.
    for (const LoopRecord &loop : loops_) {
        if (loop.end == 0) {
            issues.push_back({loop.at, true, "LOOP never closed"});
            continue;
        }
        if (loop.end > words_.size()) {
            issues.push_back({loop.at, true,
                              "LOOP body runs past the end of the program"});
        }
        int depth = 0;
        for (const LoopRecord &outer : loops_) {
            if (&outer == &loop || outer.end == 0 || loop.at <= outer.at
                || loop.at >= outer.end) {
                continue;
            }
            ++depth;
            if (loop.end > outer.end) {
                issues.push_back({loop.at, true,
                                  "LOOP body ends past its outer loop's end"});
            }
            if (outer.index == loop.index) {
                issues.push_back(
                        {loop.at, true,
                         "LOOP inside a loop on the same index register"});
            }
        }
        if (depth > 1) {
            issues.push_back(
                    {loop.at, true, "LOOP nested more than one level deep"});
        }
        if (loop.vector && loop.end <= words_.size()) {
            check_vector_body(loop, issues);
        }
    }

    // SKIP ranges: inside one loop body or outside all of them.
    for (const SkipRecord &skip : skips_) {
        if (skip.end == 0) {
            issues.push_back({skip.at, true, "SKIP never closed"});
            continue;
        }
        const size_t first = skip.at + 1;
        const size_t last  = skip.end - 1;
        for (const LoopRecord &loop : loops_) {
            if (loop.end == 0) {
                continue;
            }
            const bool skips_loop_word = loop.at >= first && loop.at <= last;
            const size_t body_first    = loop.at + 1;
            const size_t body_last     = loop.end - 1;
            const bool overlaps  = first <= body_last && last >= body_first;
            const bool contained = first >= body_first && last <= body_last;
            if (skips_loop_word || (overlaps && !contained)) {
                issues.push_back(
                        {skip.at, true, "SKIP range crosses a loop boundary"});
                break;
            }
        }
    }
    return issues;
}

} // namespace csp
