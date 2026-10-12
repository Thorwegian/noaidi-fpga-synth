// processor.hpp — the CSP reference model
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The CSP as docs/csp_manual.md specifies it, one pass at a time: the
// yardstick the RTL is checked against (#220) and the host simulator for
// CSP programs. It models what a program and the firmware can observe:
// registers, the published sink page, the index registers, the
// accumulator and flags, the write queue, reset and the pass limits. It
// does not model the pipeline's cycle-by-cycle internals, except the one
// a program can see: the IDX delay slots.

#pragma once

#include <array>
#include <cstdint>
#include <deque>
#include <set>
#include <span>
#include <string>
#include <vector>

#include "csp/csp.hpp"

namespace csp {

struct Flags {
    bool negative                        = false;
    bool zero                            = false;
    bool overflow                        = false;
    bool operator==(const Flags &) const = default;
};

// What one pass did.
struct PassReport {
    int cycles         = 0;       // instructions issued, skipped ones included
    int writes_applied = 0;       // firmware writes the window applied
    std::vector<int> stale_sinks; // owned sink words this pass did not write
    std::vector<std::string> errors;
};

class Processor {
public:
    Processor();

    // ---- firmware side ----

    // Hold the CSP in reset, or release it. A pass that starts while the
    // CSP is held runs no program; the write window then applies every
    // committed write. Reset clears no registers.
    void hold();
    void release();
    bool held() const {
        return held_;
    }

    // Load a program. Only while held; false otherwise, or if it is too
    // long.
    bool load(std::span<const uint64_t> program);

    // Queue a register write (raw 18-bit value). It has no effect until a
    // swap commits it and a pass's write window applies it.
    void write(int address, int32_t raw);

    // Queue a wide register write: two words, upper first.
    void write_wide(int address, int64_t raw);

    // The CTRL swap: commit every write queued so far.
    void swap();

    // An input register's value (the I/O region, 0x040–0x05F).
    void set_input(int address, int32_t raw);

    // ---- one pass ----

    PassReport pass();

    // ---- observation ----

    int32_t read(int address) const;      // a register, raw
    int64_t read_wide(int address) const; // a wide register pair, raw
    int32_t sink(int offset) const;       // the published sink page, raw
    int index(IndexRegister which) const;
    int64_t accumulator() const {
        return accumulator_;
    }
    Flags flags() const {
        return flags_;
    }
    size_t queued_writes() const {
        return queue_.size();
    }

private:
    struct QueuedWrite {
        int address;
        int32_t raw;
        bool committed;
    };

    struct Loop {
        IndexRegister index;
        size_t start; // first body instruction
        size_t end;   // one past the last body instruction
        int64_t remaining;
        int stride;
    };

    struct PendingIndex {
        int64_t visible_from; // the issue cycle from which it is seen
        IndexRegister index;
        int value;
    };

    // Execution state for one pass.
    struct PassState {
        size_t pc     = 0;
        int64_t cycle = 0;
        std::vector<Loop> loops;
        std::deque<PendingIndex> pending;
        int skip = 0;
        std::set<int> sinks_written;
        PassReport report;
    };

    int resolve(uint16_t field) const;
    int32_t read_operand(uint16_t field, PassState &state) const;
    int64_t read_wide_operand(uint16_t field, PassState &state) const;
    void write_operand(uint16_t field, int32_t raw, PassState &state);
    void write_wide_operand(uint16_t field, int64_t raw, PassState &state);
    void execute(const Instruction &instruction, PassState &state);
    void set_flags(int64_t result, bool overflow);
    int apply_window(int limit);

    std::array<int32_t, register_count> registers_{};
    std::array<std::array<int32_t, sink_count>, 2> sink_pages_{};
    int active_page_ = 0; // the page the partial pipeline reads
    std::set<int> owned_sinks_;
    std::array<int, 2> index_{}; // i, j
    int64_t accumulator_ = 0;
    Flags flags_;
    std::vector<uint64_t> program_;
    std::deque<QueuedWrite> queue_;
    bool held_          = true;
    int64_t pass_count_ = 0;
};

} // namespace csp
