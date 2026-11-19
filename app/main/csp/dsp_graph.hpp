// dsp_graph.hpp — the DSP graph: sources, operators, sinks and their connections
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The classic DSP flowchart as a flat netlist, the layer between the sound
// engine, which wires it up with ordinary loops, and csp::ProgramBuilder,
// which knows the hardware. A node has one output, a word or a dword. The
// graph gives every output its place in CSP memory, says where that is and
// who writes it, and turns itself into a program.
//
//   source     a value the firmware sets: a word of DMEM
//   constant   a number in the instruction that uses it
//   operator   sum, multiply, multiply-add, difference, absolute value,
//              maximum, minimum, shift, and select by a comparison
//   sink       a partial parameter: a word of the sink area
//
// A connection is a pointer, and there are three kinds of it:
//
//   fixed      the wire stays where it is, and is an address in the
//              instruction that reads it;
//   delayed    the flowchart's z⁻¹: the reader gets the value the output had
//              in the pass before. A loop in the graph goes through a delay,
//              and an operator fed by its own delayed output (an LFO's phase,
//              an envelope's level) works in place on its word;
//   movable    the wire is plugged in while the synth plays. Its reader goes
//              through a pointer, a source that holds the address of one of
//              the records the wire can be plugged into, and reads a field
//              of whichever record that is. Moving the wire is one write of
//              the pointer.
//
// A sum saturates or wraps, by its kind: the hardware has both (MAC and
// MACW), and a phase needs the one where a level needs the other.
//
// An output is a word unless it is made a dword. The hardware does dword
// arithmetic in place alone, so a dword is a source, a delay, or a sum or
// multiply-add onto its own delayed output (a phase, a level). An operator
// of words that reads a dword gets its upper word.
//
// The program is straight-line code: an instruction for every operator, no
// loop. The graph picks the order the instructions issue in, each cycle one
// whose operands are ready, with the index registers and the flags handed
// from one user to the next, so the builder has few waits left to lay
// (docs/csp2_isa.md section 8).
//
// The layout goes by reach. A direct operand reaches DMEM's first 1024
// words, which go to what fixed wires read and write; a record is reached
// through a pointer and lies in the upper half; the sinks are written
// through an index register at the end of the pass.
//
// Built without exceptions or RTTI, as the firmware is.

#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <utility>
#include <vector>

#include "csp.hpp"
#include "program_builder.hpp"

namespace csp {

class DspGraph {
public:
    enum class Width : uint8_t { word, dword };

    // What a sum does when it runs out of range.
    enum class Overflow : uint8_t { saturate, wrap };

    // A node's output as another node reads it. The default wire is not
    // connected: it reads as zero.
    struct Wire {
        int32_t node;
        constexpr Wire() : node(-1) {}
        constexpr explicit Wire(int32_t node) : node(node) {}
    };

    // Outputs laid out side by side, so that one pointer reaches all of them.
    struct Record {
        int32_t index = -1;
    };

    // A field of a record: an output, or a record inside the record.
    struct Field {
        Wire wire;
        Record record;
        Field(Wire wire) : wire(wire) {}
        Field(Record record) : record(record) {}
    };

    // ---- sources ----------------------------------------------------------

    // A value the firmware sets.
    Wire source(Width width = Width::word);
    // A raw Q4.14 number, in the instruction that reads it.
    Wire constant(int32_t raw);

    // ---- operators ---------------------------------------------------------
    //
    // Each returns its output. `a` is the operand a sum, a multiply-add or a
    // shift works on in place where nothing else reads it, and may be left
    // unconnected; a constant goes in x or y, one to an operator.

    // a + x + y
    Wire sum(Wire a, Wire x, Wire y = {}, Overflow overflow = Overflow::saturate);
    // x × y
    Wire multiply(Wire x, Wire y);
    // a + x × y, the product at full precision. With a dword `a` the output
    // and y are dwords and x is a word.
    Wire multiply_add(Wire a, Wire x, Wire y,
                      Overflow overflow = Overflow::saturate);
    // x − y
    Wire difference(Wire x, Wire y);
    // |x|
    Wire absolute(Wire x);
    Wire maximum(Wire x, Wire y);
    Wire minimum(Wire x, Wire y);
    // a × 2^places
    Wire shift(Wire a, int places);
    // if_set when x − y has the condition, otherwise if_clear
    Wire select(Wire x, Wire y, Condition condition, Wire if_clear,
                Wire if_set);

    // ---- delays -------------------------------------------------------------

    // A unit delay, z⁻¹. Its output is the value its input had in the pass
    // before; the input is connected afterwards, which closes a loop. The
    // delay is its input's word, read before the input's row renews it: so
    // its input is an operator's output, and what reads the delay is made
    // before that operator. The firmware may write the word as well (an
    // envelope's stage at a note on): address() of the delay says where.
    Wire delay(Width width = Width::word);
    void connect(Wire delay, Wire input);

    // ---- movable wires --------------------------------------------------------

    // A record of fields, in the order given. A record inside a record is
    // reached by a pointer and an offset.
    Record record(std::span<const Field> fields);
    // A pointer: a source that holds the address of one of `targets`,
    // records of one shape.
    Wire pointer(std::span<const Record> targets);
    // The field of the record a pointer points at.
    Wire through(Wire pointer, int field);
    // The same in a record inside that record: the one at `offset`, a wire
    // whose value is one of the inner records' offsets (offset_of).
    Wire through(Wire pointer, Wire offset, int field);
    // The offset of a record inside the record that holds it, as a constant
    // for the graph's own arithmetic. Inner records lie in the order given,
    // so their offsets compare as their positions do.
    Wire offset_of(Record inner);

    // ---- sinks ------------------------------------------------------------------

    // The partial parameter at `address` (csp::sink_base … ) takes `value`.
    void sink(int address, Wire value);

    // ---- the result -----------------------------------------------------------------

    struct Issue {
        std::string message;
    };

    // Lay the memory out and generate the program. False when the graph does
    // not fit the memory, the program's rows or the pass; issues() says why.
    bool build(ProgramBuilder::Built &built);
    const std::vector<Issue> &issues() const;

    // Where an output lives, once built: a source's or a pointer's word for
    // the firmware to write, an operator's for a probe to read.
    int address(Wire wire) const;
    // A record's address: what a pointer to it holds.
    int address(Record record) const;
    // An inner record's offset in its record: what an offset wire holds.
    int offset(Record inner) const;

    // Who writes a word of DMEM.
    enum class Writer : uint8_t { nobody, firmware, program };
    Writer writer(int address) const;

    DspGraph();
    ~DspGraph();

private:
    struct Node;
    struct RecordLayout;
    struct Lowering; // build()'s work: analysis, layout, order, emission

    Wire add(Node node);
    void issue(std::string message);

    std::vector<Node> nodes_;
    std::vector<RecordLayout> records_;
    std::vector<std::vector<int32_t>> target_sets_; // a pointer's records
    std::vector<std::pair<int32_t, Wire>> sinks_;   // address, value
    std::vector<Writer> writers_;                   // by DMEM address
    std::vector<Issue> issues_;
};

} // namespace csp
