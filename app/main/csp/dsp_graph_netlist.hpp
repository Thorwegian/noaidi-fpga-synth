// dsp_graph_netlist.hpp — a node of the DSP graph, and a record's layout
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The two types build() keeps its netlist in, apart from it so that a reader
// of a built graph can see what each node is and what a record holds. The
// host test's interpreter (tools/csp/test/graph_evaluator.hpp) follows them
// alone: a node's kind, its operands and its width, and a record's fields in
// order. What build() works out besides (the storage, the pointers, the
// addresses, the order of the rows) it neither needs nor reads.

#pragma once

#include <vector>

#include "dsp_graph.hpp"

namespace csp {

// The node index of nothing: an unconnected wire, an unknown record.
constexpr int32_t none = -1;

struct DspGraph::Node {
    enum class Kind : uint8_t {
        source,
        constant,
        pointer, // value: its target set
        offset,  // value: the inner record
        sum,
        multiply_add,
        difference,
        absolute,
        maximum,
        minimum,
        shift,  // value: the places
        select, // x − y compared; a if the condition is clear, b if set
        delay,  // value: its input
        through // a: the pointer, x: the offset, value: the field
    };
    Kind kind           = Kind::source;
    Width width         = Width::word;
    Overflow overflow   = Overflow::saturate;
    Condition condition = Condition::always;
    Wire a, x, y, b;
    int32_t value  = none;
    int32_t record = none; // the record this output is a field of

    // what build() works out
    int32_t shape    = none; // the set of copies its circuit is one of
    int32_t copy     = none; // which of them
    int32_t position = none; // its place in the circuit, the same in each copy
    int32_t storage  = none; // the node whose word the output lives in
    int32_t address  = none;
    int32_t group    = none; // a read through a pointer: its pointer's group
    int32_t sink     = none; // the sink word the operator writes directly
    int readers      = 0;
    bool delayed     = false; // a delay reads it
    bool fetched     = false; // a read through a pointer, into its own word
    bool in_place    = false; // the operator works on a's word
    bool copies_a    = false; // a is copied into the output's word first

    bool is_operator() const {
        return kind == Kind::sum || kind == Kind::multiply_add
               || kind == Kind::difference || kind == Kind::absolute
               || kind == Kind::maximum || kind == Kind::minimum
               || kind == Kind::shift || kind == Kind::select;
    }
};

struct DspGraph::RecordLayout {
    std::vector<Field> fields;
    std::vector<int> field_offset;
    int32_t parent  = none;
    int size        = 0;
    int alignment   = 1;
    int offset      = 0; // in its parent
    int32_t address = none;
};

} // namespace csp
