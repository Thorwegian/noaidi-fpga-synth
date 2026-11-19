// graph_evaluator.hpp — the DSP graph evaluated on the host, pass by pass
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The synth's graph as arithmetic, without a program: one value per node,
// computed in the order the nodes were made, with a delay's output the value
// its input had at the end of the pass before. It reads the netlist alone
// (app/main/csp/dsp_graph_netlist.hpp), never an address, the layout, the
// schedule or the loops, so the host test holds the graph's program to a
// second statement of what the graph means.
//
// The firmware's writes are settings: a source's word or dword, the record a
// pointer holds, the inner record an offset wire names, and a delay's held
// value (a voice's stage or level at a note). The arithmetic is the CSP's,
// written from docs/csp2_isa.md and the reference model's execute(), and
// reproduced here rather than called.
//
// Host only: no firmware file includes it.

#pragma once

#include <cstdint>
#include <vector>

#include "csp/dsp_graph.hpp"

namespace csp {

class GraphEvaluator {
public:
    // The graph must be built: an offset wire is a record's offset, which
    // build() works out.
    explicit GraphEvaluator(const DspGraph &graph);

    // ---- the firmware's writes --------------------------------------------

    // A word: a source's raw Q4.14, or a delay's held value.
    void set_word(DspGraph::Wire wire, int32_t raw);
    // A dword: a source's raw Q4.32, or a dword delay's held value.
    void set_dword(DspGraph::Wire wire, int64_t raw);
    // A movable wire: the record its pointer holds.
    void set_pointer(DspGraph::Wire wire, DspGraph::Record target);
    // A stage: an offset wire takes the inner record's own offset, the
    // number the built graph compares.
    void set_offset(DspGraph::Wire wire, DspGraph::Record inner);

    // ---- one pass -----------------------------------------------------------

    // Every node's value for this pass, then each delay takes its input's.
    void pass();

    // The value the sink at `address` was given in the last pass, as a word.
    int32_t sink(int address) const;
    // The sink addresses the graph has, in the order it made them.
    std::vector<int> sink_addresses() const;

private:
    void store(DspGraph::Wire wire, int64_t raw, int bits);
    // A wire in a word operand's place: a dword gives its upper word.
    int32_t word(DspGraph::Wire wire) const;
    // A wire as the dword it is.
    int64_t wide(DspGraph::Wire wire) const;
    int64_t through(int32_t at) const;
    // The record inside `record` whose offset is `offset`, or none.
    int32_t inner_record(int32_t record, int32_t offset) const;

    const DspGraph &graph_;
    std::vector<int64_t> values_;  // a node's output this pass
    std::vector<int64_t> held_;    // a delay's output: the pass before's input
    std::vector<int32_t> pointed_; // the record each pointer holds
};

} // namespace csp
