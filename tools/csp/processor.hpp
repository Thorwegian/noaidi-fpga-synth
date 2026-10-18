// processor.hpp — the CSP reference model
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The CSP as docs/csp2_isa.md specifies it, one pass at a time: the
// yardstick the RTL is checked against (#235) and the host simulator for
// CSP programs. It runs an image — the rows and the decode ROM the
// assembler made — and models what a program and the firmware can
// observe: registers, the published sink page, the index registers, the
// accumulator and flags, the write FIFO, the hold and the pass's limit.
//
// The chip has no interlock, so the model does not wait either: it counts
// the cycle every row issues in, exactly as the front end does (one a
// cycle, the index barrier, the jump penalty, a vector loop's rounds),
// keeps a scoreboard of when each value is written, and reports a row
// that reads a value before it is ready — the proof that the assembler's
// schedule is the chip's. Likewise an indexed access whose offset's bits
// overlap the index's (the chip ORs them; the program meant a sum) is
// reported, not silently allowed.

#pragma once

#include <array>
#include <cstdint>
#include <deque>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "csp/csp.hpp"
#include "csp/program_builder.hpp"

namespace csp {

struct Flags {
    bool negative                        = false;
    bool zero                            = false;
    bool overflow                        = false;
    bool operator==(const Flags &) const = default;
};

// What one pass did.
struct PassReport {
    int cycles         = 0; // the cycle the next row would issue at
    int writes_applied = 0; // firmware writes the window applied
    std::vector<int> stale_sinks; // owned sink words this pass did not write
    std::vector<std::string> errors;
};

class Processor {
public:
    Processor();

    // ---- firmware side ----

    // Hold the CSP, or release it. A pass that starts while the CSP is held
    // runs no program; the write window then applies every committed write.
    // Reset clears no registers.
    void hold();
    void release();
    bool held() const { return held_; }

    // Load an image. Only while held; false otherwise.
    bool load(const Image &image);

    // Queue a register write (raw 18-bit value). It has no effect until a
    // swap commits it and a pass's write window applies it.
    void write(int address, int32_t raw);
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
    int64_t accumulator() const { return accumulator_; }
    Flags flags() const { return flags_; }
    size_t queued_writes() const { return queue_.size(); }
    int64_t pass_count() const { return pass_count_; }

    // Print each row as it issues (row, cycle, i, j) to stderr.
    void trace(bool on) { trace_ = on; }

private:
    struct QueuedWrite {
        int address;
        int32_t raw;
        bool committed;
    };

    struct Loop {
        IndexRegister index;
        size_t start; // first body row
        size_t end;   // one past the last body row
        int remaining;
        int stride;
    };

    // When each value may next be read: the schedule's proof. The flags,
    // the accumulator and the index registers are per element inside a
    // vector loop (run_vector swaps them with the element).
    struct Scoreboard {
        std::array<int64_t, register_count> register_ready{};
        int64_t state_ready = 0;   // the flags and the accumulator
        std::array<int64_t, 2> index_ready{};
    };

    // A vector loop in progress: the element issuing, and who wrote and
    // read which register, to catch elements that depend on each other.
    struct VectorRun {
        IndexRegister private_index;
        int element = 0;
        std::map<int, int> writer;
        std::map<int, std::set<int>> readers;
    };

    struct PassState {
        size_t pc     = 0;
        int64_t cycle = 0;
        Scoreboard scoreboard;
        std::vector<Loop> loops;
        int skip = 0;
        std::set<int> sinks_written;
        std::optional<VectorRun> vector;
        bool stopped = false;
        PassReport report;
    };

    struct Decoded {
        Word word;
        Control control;
        Op op;          // the operation the control word names, with its sub-op
    };

    Decoded decode(size_t row) const;
    int resolve(const Operand &operand) const;
    int resolve_checked(const Operand &operand, PassState &state) const;
    int32_t read_operand(const Operand &operand, int32_t immediate, PassState &state, bool check_ready);
    int64_t read_wide_operand(const Operand &operand, PassState &state);
    void write_operand(const Operand &operand, int32_t raw, PassState &state);
    void write_wide_operand(const Operand &operand, int64_t raw, PassState &state);
    void check_ready(int address, bool wide, PassState &state) const;
    void note_writes(const Decoded &decoded, PassState &state);
    void execute(const Decoded &decoded, PassState &state);
    void run_vector(const Decoded &decoded, size_t at, PassState &state);
    void note_access(int address, bool write, PassState &state) const;
    void end_loops(PassState &state);
    void set_flags(int64_t result, bool overflow);
    int apply_window(int limit);

    std::array<int32_t, register_count> registers_{};
    std::array<std::array<int32_t, sink_count>, 2> sink_pages_{};
    int active_page_ = 0;
    std::set<int> owned_sinks_;
    std::array<int, 2> index_{};
    int64_t accumulator_ = 0;
    Flags flags_;
    Image image_;
    std::deque<QueuedWrite> queue_;
    bool held_          = true;
    bool trace_         = false;
    int64_t pass_count_ = 0;
};

} // namespace csp
