// graph_evaluator.cpp — the DSP graph's arithmetic (see graph_evaluator.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Every operation as the CSP does it, in raw numbers: a word is Q4.14 and a
// dword Q4.32; a sum is formed at full width and saturated, or wrapped, to
// the destination; a product keeps 14 fraction bits more than a word, and
// what falls below the destination's smallest step is truncated toward minus
// infinity; a shift multiplies by a power of two before the same truncation.
// Flags belong to a compare, and are its difference's after the saturation,
// which is the value the hardware would have stored.

#include "graph_evaluator.hpp"

#include <algorithm>

#include "csp/dsp_graph_netlist.hpp"

namespace csp {

namespace {

constexpr int max_shift = 63;

struct Flags {
    bool negative = false;
    bool zero     = false;
    bool overflow = false;
};

int64_t saturate(int64_t value, int bits) {
    return std::clamp(value, smallest(bits), largest(bits));
}

int64_t wrap(int64_t value, int bits) {
    return sign_extend(value, bits);
}

// A word times another operand, in the destination's fraction bits: the
// exact product truncated toward minus infinity, as the model's shift of the
// product down by the word's fraction bits does.
int64_t product(int64_t x, int64_t y) {
    return (x * y) >> word_fraction_bits;
}

// A word operand of a dword sum: 18 bits below the dword, which is where the
// accumulator puts it.
int64_t raised_word(int64_t word) {
    return word << (wide_fraction_bits - word_fraction_bits);
}

// A × 2^places at the destination's width: a shift up saturates, a shift
// down truncates toward minus infinity.
int64_t shifted(int64_t value, int64_t places, int bits) {
    places = std::clamp<int64_t>(places, -max_shift, max_shift);
    if (places < 0) {
        return value >> -places;
    }
    const auto raised = static_cast<__int128>(value) << places;
    return static_cast<int64_t>(
            std::clamp<__int128>(raised, smallest(bits), largest(bits)));
}

// A compare's flags. The difference is saturated to a word first, the value
// the hardware stores, so a difference out of range flags overflow and takes
// the sign of its saturated value.
Flags flags_of(int64_t difference) {
    const int64_t result = saturate(difference, word_bits);
    return {result < 0, result == 0, result != difference};
}

bool condition_holds(Condition condition, const Flags &flags) {
    switch (condition) {
    case Condition::always:
        return true;
    case Condition::negative:
        return flags.negative;
    case Condition::positive:
        return !flags.negative;
    case Condition::zero:
        return flags.zero;
    case Condition::nonzero:
        return !flags.zero;
    case Condition::overflow:
        return flags.overflow;
    }
    return false;
}

} // namespace

GraphEvaluator::GraphEvaluator(const DspGraph &graph)
    : graph_(graph), values_(graph.nodes_.size(), 0),
      held_(graph.nodes_.size(), 0), pointed_(graph.nodes_.size(), none) {
    // the numbers the graph carries itself: a constant's, and the offset an
    // inner record lies at
    for (size_t at = 0; at < graph.nodes_.size(); ++at) {
        const DspGraph::Node &node = graph.nodes_[at];
        if (node.kind == DspGraph::Node::Kind::constant) {
            values_[at] = node.value;
        } else if (node.kind == DspGraph::Node::Kind::offset) {
            values_[at] = graph.offset(DspGraph::Record{node.value});
        }
    }
}

void GraphEvaluator::store(DspGraph::Wire wire, int64_t raw, int bits) {
    if (wire.node == none) {
        return;
    }
    const int64_t value = sign_extend(raw, bits);
    const auto at       = static_cast<size_t>(wire.node);
    if (graph_.nodes_[at].kind == DspGraph::Node::Kind::delay) {
        // the word a delay reads before its input's row renews it
        held_[at] = value;
    }
    values_[at] = value;
}

void GraphEvaluator::set_word(DspGraph::Wire wire, int32_t raw) {
    store(wire, raw, word_bits);
}

void GraphEvaluator::set_dword(DspGraph::Wire wire, int64_t raw) {
    store(wire, raw, dword_bits);
}

void GraphEvaluator::set_pointer(DspGraph::Wire wire, DspGraph::Record target) {
    if (wire.node != none) {
        pointed_[static_cast<size_t>(wire.node)] = target.index;
    }
}

void GraphEvaluator::set_offset(DspGraph::Wire wire, DspGraph::Record inner) {
    store(wire, graph_.offset(inner), word_bits);
}

int32_t GraphEvaluator::word(DspGraph::Wire wire) const {
    if (wire.node == none) {
        return 0;
    }
    const auto at = static_cast<size_t>(wire.node);
    // an operator of words that reads a dword gets its upper word
    return graph_.nodes_[at].width == DspGraph::Width::dword
                   ? static_cast<int32_t>(
                             sign_extend(values_[at] >> word_bits, word_bits))
                   : static_cast<int32_t>(values_[at]);
}

int64_t GraphEvaluator::wide(DspGraph::Wire wire) const {
    return wire.node == none ? 0 : values_[static_cast<size_t>(wire.node)];
}

int32_t GraphEvaluator::inner_record(int32_t record, int32_t offset) const {
    for (const DspGraph::Field &field :
         graph_.records_[static_cast<size_t>(record)].fields) {
        if (field.record.index != none
            && graph_.offset(field.record) == offset) {
            return field.record.index;
        }
    }
    return none;
}

int64_t GraphEvaluator::through(int32_t at) const {
    const DspGraph::Node &read = graph_.nodes_[static_cast<size_t>(at)];
    if (read.a.node == none) {
        return 0;
    }
    int32_t record = pointed_[static_cast<size_t>(read.a.node)];
    if (record == none) {
        return 0; // a pointer the firmware has not set
    }
    if (read.x.node != none) {
        record = inner_record(record, word(read.x));
        if (record == none) {
            return 0; // no record of that offset: nothing the graph made
        }
    }
    const DspGraph::RecordLayout &layout =
            graph_.records_[static_cast<size_t>(record)];
    if (read.value < 0
        || read.value >= static_cast<int32_t>(layout.fields.size())) {
        return 0;
    }
    const DspGraph::Field &field =
            layout.fields[static_cast<size_t>(read.value)];
    if (field.wire.node == none) {
        return 0;
    }
    return read.width == DspGraph::Width::dword ? wide(field.wire)
                                                : word(field.wire);
}

void GraphEvaluator::pass() {
    for (size_t at = 0; at < graph_.nodes_.size(); ++at) {
        const DspGraph::Node &node = graph_.nodes_[at];
        const bool wide_node       = node.width == DspGraph::Width::dword;
        const int bits             = wide_node ? dword_bits : word_bits;
        switch (node.kind) {
        case DspGraph::Node::Kind::source:
        case DspGraph::Node::Kind::constant:
        case DspGraph::Node::Kind::pointer:
        case DspGraph::Node::Kind::offset:
            break; // what the firmware set, or a number of the graph's
        case DspGraph::Node::Kind::delay:
            values_[at] = held_[at];
            break;
        case DspGraph::Node::Kind::through:
            values_[at] = through(static_cast<int32_t>(at));
            break;
        case DspGraph::Node::Kind::sum: {
            const int64_t a = wide_node ? wide(node.a) : word(node.a);
            if (node.overflow == DspGraph::Overflow::wrap) {
                // a + 1.0 × x: the x is the destination's own width, so a
                // dword's step is exact
                const int64_t x = wide_node ? wide(node.x) : word(node.x);
                values_[at]     = wrap(a + x, bits);
                break;
            }
            // a + x + y: a dword sum takes x as a word, 18 bits below
            const int64_t x =
                    wide_node ? raised_word(word(node.x)) : word(node.x);
            const int64_t y = wide_node ? wide(node.y) : word(node.y);
            values_[at]     = saturate(a + x + y, bits);
            break;
        }
        case DspGraph::Node::Kind::multiply_add: {
            // a + x × y: x is a word, y the destination's width
            const int64_t a   = wide_node ? wide(node.a) : word(node.a);
            const int64_t y   = wide_node ? wide(node.y) : word(node.y);
            const int64_t sum = a + product(word(node.x), y);
            values_[at]       = node.overflow == DspGraph::Overflow::wrap
                                        ? wrap(sum, bits)
                                        : saturate(sum, bits);
            break;
        }
        case DspGraph::Node::Kind::difference:
            values_[at] = saturate(word(node.x) - word(node.y), word_bits);
            break;
        case DspGraph::Node::Kind::absolute: {
            const int64_t x = word(node.x);
            values_[at]     = saturate(x < 0 ? -x : x, word_bits);
            break;
        }
        case DspGraph::Node::Kind::maximum:
            values_[at] = std::max(word(node.x), word(node.y));
            break;
        case DspGraph::Node::Kind::minimum:
            values_[at] = std::min(word(node.x), word(node.y));
            break;
        case DspGraph::Node::Kind::shift:
            values_[at] = shifted(wide_node ? wide(node.a) : word(node.a),
                                  node.value, bits);
            break;
        case DspGraph::Node::Kind::select: {
            // x − y sets the flags; a is the result if the condition is
            // clear, b if it holds
            const Flags flags = flags_of(word(node.x) - word(node.y));
            values_[at] = condition_holds(node.condition, flags) ? word(node.b)
                                                                 : word(node.a);
            break;
        }
        }
    }
    // each delay takes its input's value for the next pass
    for (size_t at = 0; at < graph_.nodes_.size(); ++at) {
        const DspGraph::Node &node = graph_.nodes_[at];
        if (node.kind == DspGraph::Node::Kind::delay && node.value != none) {
            held_[at] = values_[static_cast<size_t>(node.value)];
        }
    }
}

int64_t GraphEvaluator::probe(DspGraph::Wire wire) const {
    return wire.node == none ? 0 : values_[static_cast<size_t>(wire.node)];
}

int32_t GraphEvaluator::sink(int address) const {
    int32_t value = 0;
    for (const auto &[at, wire] : graph_.sinks_) {
        if (at == address) {
            value = word(wire);
        }
    }
    return value;
}

std::vector<int> GraphEvaluator::sink_addresses() const {
    std::vector<int> addresses;
    for (const auto &sink : graph_.sinks_) {
        if (std::find(addresses.begin(), addresses.end(), sink.first)
            == addresses.end()) {
            addresses.push_back(sink.first);
        }
    }
    return addresses;
}

} // namespace csp
