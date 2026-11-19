// dsp_graph.cpp — the DSP graph laid out, ordered and emitted (see dsp_graph.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// build() works in steps, the first Copies' and the rest each a part of
// Lowering below:
//
//   copies        the circuits of one shape among the graph's nodes, found
//                 from its structure;
//   loops         which sets of copies run as the elements of a vector loop:
//                 those of enough copies, whose sinks lie in blocks of one
//                 layout and whose pointers point outside the set;
//   storage       which reads through a pointer are fetched into a word of
//                 their own, and which operators work in place: one that
//                 accumulates onto an operand nothing else reads takes that
//                 operand's word, and a delay is its input's word;
//   instructions  every node as the rows it takes, in the order the nodes
//                 were made, which is an order the values can be computed
//                 in: a loop's body from its first copy, the straight-line
//                 code from the nodes of no loop. A row names nodes, not
//                 addresses;
//   bodies        each loop's rows ordered, a row of the body at a time,
//                 and its copy's record laid out from that order: a word
//                 for every value that lasts, and the others sharing words
//                 where their lives do not meet;
//   layout        the loops' records from the top of DMEM down, the rest
//                 from the direct half up;
//   dependencies  which instruction must issue how many cycles behind which,
//                 read off the addresses the instructions name, each loop
//                 an instruction among the straight-line rows;
//   order         a list scheduler: a cycle at a time, an instruction whose
//                 predecessors are far enough behind, j and the flags each
//                 with one user at a time;
//   emission      through csp::ProgramBuilder, which lays the waits that are
//                 left, proves the schedule and encodes.
//
// The index registers. In a loop i is the loop's, the element's record, and
// j the element's own: each pointer's in turn, and the pointer to its block
// of sinks. In straight-line code j is each pointer's in turn and the sink
// area's base for the rows that write sinks, which come last; i holds the
// upper half's base where the program has no loop, so an address there is
// an offset through i.

#include "dsp_graph.hpp"

#include <algorithm>
#include <array>
#include <map>

namespace csp {

namespace {

constexpr int32_t none      = -1;
constexpr int direct_first  = io_base + io_count; // behind the inputs
constexpr int high_base     = direct_reach; // DMEM's upper half, through i
constexpr int sink_area_end = sink_base + sink_count;

int power_of_two_at_least(int size) {
    int power = 1;
    while (power < size) {
        power *= 2;
    }
    return power;
}

int aligned(int at, int alignment) {
    return (at + alignment - 1) / alignment * alignment;
}

} // namespace

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

// A set of copies: circuits of one shape.
struct DspGraph::Shape {
    // Each copy's nodes. The nodes at one position correspond.
    std::vector<std::vector<int32_t>> copies;
};

// ---- building the graph --------------------------------------------------------

DspGraph::DspGraph() : writers_(register_count, Writer::nobody) {}
DspGraph::~DspGraph() = default;

DspGraph::Wire DspGraph::add(Node node) {
    nodes_.push_back(node);
    return Wire{static_cast<int32_t>(nodes_.size()) - 1};
}

void DspGraph::issue(std::string message) {
    issues_.push_back({std::move(message)});
}

DspGraph::Wire DspGraph::source(Width width) {
    Node node;
    node.kind  = Node::Kind::source;
    node.width = width;
    return add(node);
}

DspGraph::Wire DspGraph::constant(int32_t raw) {
    Node node;
    node.kind  = Node::Kind::constant;
    node.value = raw;
    return add(node);
}

DspGraph::Wire DspGraph::sum(Wire a, Wire x, Wire y, Overflow overflow) {
    Node node;
    node.kind     = Node::Kind::sum;
    node.a        = a;
    node.x        = x;
    node.y        = y;
    node.overflow = overflow;
    node.width    = a.node == none ? Width::word
                                   : nodes_[static_cast<size_t>(a.node)].width;
    return add(node);
}

DspGraph::Wire DspGraph::multiply(Wire x, Wire y) {
    return multiply_add({}, x, y);
}

DspGraph::Wire DspGraph::multiply_add(Wire a, Wire x, Wire y,
                                      Overflow overflow) {
    Node node;
    node.kind     = Node::Kind::multiply_add;
    node.a        = a;
    node.x        = x;
    node.y        = y;
    node.overflow = overflow;
    node.width    = a.node == none ? Width::word
                                   : nodes_[static_cast<size_t>(a.node)].width;
    return add(node);
}

DspGraph::Wire DspGraph::difference(Wire x, Wire y) {
    Node node;
    node.kind = Node::Kind::difference;
    node.x    = x;
    node.y    = y;
    return add(node);
}

DspGraph::Wire DspGraph::absolute(Wire x) {
    Node node;
    node.kind = Node::Kind::absolute;
    node.x    = x;
    return add(node);
}

DspGraph::Wire DspGraph::maximum(Wire x, Wire y) {
    Node node;
    node.kind = Node::Kind::maximum;
    node.x    = x;
    node.y    = y;
    return add(node);
}

DspGraph::Wire DspGraph::minimum(Wire x, Wire y) {
    Node node;
    node.kind = Node::Kind::minimum;
    node.x    = x;
    node.y    = y;
    return add(node);
}

DspGraph::Wire DspGraph::shift(Wire a, int places) {
    Node node;
    node.kind  = Node::Kind::shift;
    node.a     = a;
    node.value = places;
    node.width = a.node == none ? Width::word
                                : nodes_[static_cast<size_t>(a.node)].width;
    return add(node);
}

DspGraph::Wire DspGraph::select(Wire x, Wire y, Condition condition,
                                Wire if_clear, Wire if_set) {
    Node node;
    node.kind      = Node::Kind::select;
    node.x         = x;
    node.y         = y;
    node.a         = if_clear;
    node.b         = if_set;
    node.condition = condition;
    return add(node);
}

DspGraph::Wire DspGraph::delay(Width width) {
    Node node;
    node.kind  = Node::Kind::delay;
    node.width = width;
    return add(node);
}

void DspGraph::connect(Wire delay, Wire input) {
    Node &node = nodes_[static_cast<size_t>(delay.node)];
    if (node.kind != Node::Kind::delay || input.node == none) {
        issue("connect() takes a delay and the output that feeds it");
        return;
    }
    if (node.width != nodes_[static_cast<size_t>(input.node)].width) {
        issue("a delay and its input are of one width");
    }
    node.value = input.node;
}

DspGraph::Record DspGraph::record(std::span<const Field> fields) {
    const auto index = static_cast<int32_t>(records_.size());
    RecordLayout layout;
    layout.fields.assign(fields.begin(), fields.end());
    for (const Field &field : fields) {
        if (field.record.index != none) {
            records_[static_cast<size_t>(field.record.index)].parent = index;
        } else if (field.wire.node != none) {
            Node &node = nodes_[static_cast<size_t>(field.wire.node)];
            if (node.record != none) {
                issue("an output is a field of one record");
            }
            node.record = index;
        }
    }
    records_.push_back(std::move(layout));
    return {index};
}

DspGraph::Wire DspGraph::pointer(std::span<const Record> targets) {
    std::vector<int32_t> set;
    for (const Record &target : targets) {
        set.push_back(target.index);
    }
    Node node;
    node.kind  = Node::Kind::pointer;
    node.value = static_cast<int32_t>(target_sets_.size());
    target_sets_.push_back(std::move(set));
    return add(node);
}

DspGraph::Wire DspGraph::through(Wire pointer, int field) {
    return through(pointer, {}, field);
}

DspGraph::Wire DspGraph::through(Wire pointer, Wire offset, int field) {
    Node node;
    node.kind  = Node::Kind::through;
    node.a     = pointer;
    node.x     = offset;
    node.value = field;
    // the field's width, by the first record the pointer can hold
    const Node &from = nodes_[static_cast<size_t>(pointer.node)];
    if (from.kind != Node::Kind::pointer
        || target_sets_[static_cast<size_t>(from.value)].empty()) {
        issue("through() takes a pointer with records to point at");
        return add(node);
    }
    const RecordLayout *record = &records_[static_cast<size_t>(
            target_sets_[static_cast<size_t>(from.value)].front())];
    if (offset.node != none) {
        const RecordLayout *inner = nullptr;
        for (const Field &inside : record->fields) {
            if (inside.record.index != none) {
                inner = &records_[static_cast<size_t>(inside.record.index)];
                break;
            }
        }
        if (!inner) {
            issue("an offset needs a record inside the record");
            return add(node);
        }
        record = inner;
    }
    if (field < 0 || field >= static_cast<int>(record->fields.size())
        || record->fields[static_cast<size_t>(field)].wire.node == none) {
        issue("through() names an output among the record's fields");
        return add(node);
    }
    node.width = nodes_[static_cast<size_t>(
                                record->fields[static_cast<size_t>(field)]
                                        .wire.node)]
                         .width;
    return add(node);
}

DspGraph::Wire DspGraph::offset_of(Record inner) {
    Node node;
    node.kind  = Node::Kind::offset;
    node.value = inner.index;
    return add(node);
}

void DspGraph::sink(int address, Wire value) {
    if (address < sink_base || address >= sink_area_end || value.node == none) {
        issue("a sink is a word of the sink area with a value");
        return;
    }
    sinks_.push_back({address, value});
}

const std::vector<DspGraph::Issue> &DspGraph::issues() const {
    return issues_;
}

int DspGraph::address(Wire wire) const {
    return wire.node == none ? none
                             : nodes_[static_cast<size_t>(wire.node)].address;
}

int DspGraph::address(Record record) const {
    return records_[static_cast<size_t>(record.index)].address;
}

int DspGraph::offset(Record inner) const {
    return records_[static_cast<size_t>(inner.index)].offset;
}

DspGraph::Writer DspGraph::writer(int address) const {
    return address >= 0 && address < register_count
                   ? writers_[static_cast<size_t>(address)]
                   : Writer::nobody;
}

const std::vector<DspGraph::CopySet> &DspGraph::copy_sets() const {
    return copy_sets_;
}

const std::vector<DspGraph::InitialValue> &DspGraph::initial_values() const {
    return initial_values_;
}

// ---- the copies ---------------------------------------------------------------------
//
// Circuits of one shape, found from the graph's structure alone: the top
// says nothing of its loops. Every node gets a colour from what it is, and
// the colours are refined round by round with the colours of what the node
// reads and of what reads it, until no round tells two more nodes apart
// (colour refinement, the first step of a graph isomorphism test). A node
// whose colour no other node has is the only one of its kind, and belongs
// to no copy. The others fall into circuits, each the nodes that wires,
// delays and records connect among themselves. Circuits of the same colours
// are then compared node by node, so that two shapes with one colour by
// accident, or two circuits whose like nodes were made in another order,
// are told apart here and stay straight-line code: a wrong colour costs a
// loop, never a wrong program.

struct DspGraph::Copies {
    using Kind = Node::Kind;

    DspGraph &graph;
    std::vector<Node> &nodes;
    std::vector<uint64_t> colour;
    // who reads each node, and as which operand
    std::vector<std::vector<std::pair<int32_t, int>>> readers;
    std::vector<int> sinks_fed;
    std::vector<int32_t> field_of; // a node's place among its record's fields
    std::vector<int32_t> circuit;  // none: the only one of its kind
    std::vector<std::vector<int32_t>> circuits;

    static constexpr int operand_count = 4;
    static constexpr int delay_input   = operand_count;

    explicit Copies(DspGraph &graph) : graph(graph), nodes(graph.nodes_) {}

    static constexpr uint64_t mixed(uint64_t hash, uint64_t value) {
        hash ^= value + 0x9E3779B97F4A7C15ull + (hash << 12) + (hash >> 4);
        hash *= 0xFF51AFD7ED558CCDull;
        return hash ^ (hash >> 33);
    }

    static std::array<Wire, operand_count> operands(const Node &node) {
        return {node.a, node.x, node.y, node.b};
    }

    const RecordLayout &record(int32_t index) const {
        return graph.records_[static_cast<size_t>(index)];
    }

    int32_t outermost(int32_t index) const {
        while (record(index).parent != none) {
            index = record(index).parent;
        }
        return index;
    }

    bool is_immediate(int32_t at) const {
        const Kind kind = nodes[static_cast<size_t>(at)].kind;
        return kind == Kind::constant || kind == Kind::offset;
    }

    // ---- colours ---------------------------------------------------------------

    void find_readers() {
        readers.assign(nodes.size(), {});
        sinks_fed.assign(nodes.size(), 0);
        field_of.assign(nodes.size(), none);
        for (size_t at = 0; at < nodes.size(); ++at) {
            const auto wires = operands(nodes[at]);
            for (int slot = 0; slot < operand_count; ++slot) {
                if (wires[static_cast<size_t>(slot)].node != none) {
                    readers[static_cast<size_t>(
                                    wires[static_cast<size_t>(slot)].node)]
                            .push_back({static_cast<int32_t>(at), slot});
                }
            }
            if (nodes[at].kind == Kind::delay && nodes[at].value != none) {
                readers[static_cast<size_t>(nodes[at].value)].push_back(
                        {static_cast<int32_t>(at), delay_input});
            }
        }
        for (const auto &[address, value] : graph.sinks_) {
            ++sinks_fed[static_cast<size_t>(value.node)];
        }
        for (const RecordLayout &layout : graph.records_) {
            for (size_t field = 0; field < layout.fields.size(); ++field) {
                if (layout.fields[field].wire.node != none) {
                    field_of[static_cast<size_t>(
                            layout.fields[field].wire.node)] =
                            static_cast<int32_t>(field);
                }
            }
        }
    }

    // Where a record lies in its outermost record: the fields on the way down.
    uint64_t place_colour(int32_t index) const {
        uint64_t hash = 0;
        for (; record(index).parent != none; index = record(index).parent) {
            const RecordLayout &parent = record(record(index).parent);
            for (size_t field = 0; field < parent.fields.size(); ++field) {
                if (parent.fields[field].record.index == index) {
                    hash = mixed(hash, field + 1);
                }
            }
        }
        return hash;
    }

    // What a node is, before anything is known of its neighbours.
    uint64_t own_colour(size_t at) const {
        const Node &node = nodes[at];
        uint64_t hash    = mixed(static_cast<uint64_t>(node.kind),
                                 static_cast<uint64_t>(node.width));
        hash             = mixed(hash, static_cast<uint64_t>(node.overflow));
        hash             = mixed(hash, static_cast<uint64_t>(node.condition));
        hash             = mixed(hash, static_cast<uint64_t>(sinks_fed[at]));
        switch (node.kind) {
        case Kind::constant:
        case Kind::offset:
        case Kind::shift:
        case Kind::through:
            hash = mixed(hash, static_cast<uint64_t>(node.value));
            break;
        case Kind::pointer:
            for (const int32_t target :
                 graph.target_sets_[static_cast<size_t>(node.value)]) {
                hash = mixed(hash, static_cast<uint64_t>(target));
            }
            break;
        default:
            break;
        }
        if (node.record != none) {
            hash = mixed(hash, place_colour(node.record));
            hash = mixed(hash, static_cast<uint64_t>(field_of[at]) + 1);
        }
        return hash;
    }

    // The colour of a record with all that is in it.
    uint64_t record_colour(int32_t index) const {
        uint64_t hash = 0;
        for (const Field &field : record(index).fields) {
            hash = mixed(hash,
                         field.record.index != none
                                 ? record_colour(field.record.index)
                         : field.wire.node != none
                                 ? colour[static_cast<size_t>(field.wire.node)]
                                 : 0);
        }
        return hash;
    }

    // One round: every colour with its neighbours' colours added.
    void refine() {
        std::vector<uint64_t> next(nodes.size());
        for (size_t at = 0; at < nodes.size(); ++at) {
            uint64_t hash = colour[at];
            for (const Wire wire : operands(nodes[at])) {
                hash = mixed(hash,
                             wire.node != none
                                     ? colour[static_cast<size_t>(wire.node)]
                                     : 0);
            }
            if (nodes[at].kind == Kind::delay && nodes[at].value != none) {
                hash = mixed(hash,
                             colour[static_cast<size_t>(nodes[at].value)]);
            }
            uint64_t read_by = 0; // a sum: in whatever order the readers come
            for (const auto &[reader, slot] : readers[at]) {
                read_by += mixed(colour[static_cast<size_t>(reader)],
                                 static_cast<uint64_t>(slot));
            }
            next[at] = mixed(hash, read_by);
        }
        for (size_t index = 0; index < graph.records_.size(); ++index) {
            if (graph.records_[index].parent != none) {
                continue;
            }
            const uint64_t whole = record_colour(static_cast<int32_t>(index));
            for_each_field(static_cast<int32_t>(index), [&](int32_t node) {
                next[static_cast<size_t>(node)] =
                        mixed(next[static_cast<size_t>(node)], whole);
            });
        }
        colour = std::move(next);
    }

    template <typename Visit>
    void for_each_field(int32_t index, Visit visit) {
        for (const Field &field : record(index).fields) {
            if (field.record.index != none) {
                for_each_field(field.record.index, visit);
            } else if (field.wire.node != none) {
                visit(field.wire.node);
            }
        }
    }

    size_t colours_in_use() const {
        std::vector<uint64_t> sorted = colour;
        std::sort(sorted.begin(), sorted.end());
        return static_cast<size_t>(std::unique(sorted.begin(), sorted.end())
                                   - sorted.begin());
    }

    void find_colours() {
        colour.resize(nodes.size());
        for (size_t at = 0; at < nodes.size(); ++at) {
            colour[at] = own_colour(at);
        }
        // a round only ever splits colours: when none split, none will
        for (size_t before = colours_in_use(), round = 0; round < nodes.size();
             ++round) {
            refine();
            const size_t after = colours_in_use();
            if (after == before) {
                break;
            }
            before = after;
        }
    }

    // ---- circuits --------------------------------------------------------------

    void find_circuits() {
        std::map<uint64_t, int> of_colour;
        for (const uint64_t each : colour) {
            ++of_colour[each];
        }
        std::vector<int32_t> joined(nodes.size());
        for (size_t at = 0; at < nodes.size(); ++at) {
            joined[at] =
                    of_colour[colour[at]] > 1 ? static_cast<int32_t>(at) : none;
        }
        auto root = [&](int32_t at) {
            while (joined[static_cast<size_t>(at)] != at) {
                at = joined[static_cast<size_t>(at)] =
                        joined[static_cast<size_t>(
                                joined[static_cast<size_t>(at)])];
            }
            return at;
        };
        auto join = [&](int32_t one, int32_t other) {
            if (one != none && other != none
                && joined[static_cast<size_t>(one)] != none
                && joined[static_cast<size_t>(other)] != none) {
                joined[static_cast<size_t>(root(one))] = root(other);
            }
        };
        for (size_t at = 0; at < nodes.size(); ++at) {
            for (const Wire wire : operands(nodes[at])) {
                join(static_cast<int32_t>(at), wire.node);
            }
            if (nodes[at].kind == Kind::delay) {
                join(static_cast<int32_t>(at), nodes[at].value);
            }
        }
        for (size_t index = 0; index < graph.records_.size(); ++index) {
            if (graph.records_[index].parent == none) {
                int32_t first = none;
                for_each_field(static_cast<int32_t>(index), [&](int32_t node) {
                    join(node, first);
                    first = node;
                });
            }
        }
        circuit.assign(nodes.size(), none);
        circuits.clear();
        std::map<int32_t, int32_t> circuit_of_root;
        for (size_t at = 0; at < nodes.size(); ++at) {
            if (joined[at] == none) {
                continue;
            }
            const auto [found, made] = circuit_of_root.try_emplace(
                    root(static_cast<int32_t>(at)),
                    static_cast<int32_t>(circuits.size()));
            if (made) {
                circuits.push_back({});
            }
            circuit[at] = found->second;
            circuits[static_cast<size_t>(found->second)].push_back(
                    static_cast<int32_t>(at));
        }
        // a circuit's nodes by colour, like nodes in the order they were made
        for (std::vector<int32_t> &each : circuits) {
            std::stable_sort(each.begin(), each.end(),
                             [&](int32_t one, int32_t other) {
                                 return colour[static_cast<size_t>(one)]
                                        < colour[static_cast<size_t>(other)];
                             });
            for (size_t position = 0; position < each.size(); ++position) {
                nodes[static_cast<size_t>(each[position])].position =
                        static_cast<int32_t>(position);
            }
        }
    }

    // ---- the comparison ----------------------------------------------------------

    // Whether two wires of two circuits lead to the same place: to the node
    // at one position in each, to one node outside both, or to one number.
    bool corresponds(int32_t ours, int32_t theirs, int32_t our_circuit,
                     int32_t their_circuit) const {
        if (ours == none || theirs == none) {
            return ours == theirs;
        }
        const Node &one = nodes[static_cast<size_t>(ours)];
        const Node &two = nodes[static_cast<size_t>(theirs)];
        if (is_immediate(ours) || is_immediate(theirs)) {
            return one.kind == two.kind && one.value == two.value;
        }
        const bool inside = circuit[static_cast<size_t>(ours)] == our_circuit;
        if (inside != (circuit[static_cast<size_t>(theirs)] == their_circuit)) {
            return false;
        }
        return inside ? one.position == two.position : ours == theirs;
    }

    bool records_correspond(int32_t ours, int32_t theirs, int32_t our_circuit,
                            int32_t their_circuit) const {
        const std::vector<Field> &one = record(ours).fields;
        const std::vector<Field> &two = record(theirs).fields;
        if (one.size() != two.size()) {
            return false;
        }
        for (size_t field = 0; field < one.size(); ++field) {
            const bool inner = one[field].record.index != none;
            if (inner != (two[field].record.index != none)) {
                return false;
            }
            if (inner ? !records_correspond(one[field].record.index,
                                            two[field].record.index,
                                            our_circuit, their_circuit)
                      : !corresponds(one[field].wire.node, two[field].wire.node,
                                     our_circuit, their_circuit)) {
                return false;
            }
        }
        return true;
    }

    // Whether nothing outside a circuit reads into it: what a copy computes
    // is its own until a pointer or a sink takes it.
    bool is_closed(int32_t index) const {
        for (const int32_t at : circuits[static_cast<size_t>(index)]) {
            for (const auto &[reader, slot] :
                 readers[static_cast<size_t>(at)]) {
                if (circuit[static_cast<size_t>(reader)] != index
                    && !is_immediate(at)) {
                    return false;
                }
            }
        }
        return true;
    }

    bool same_shape(int32_t our_circuit, int32_t their_circuit) const {
        const std::vector<int32_t> &ours =
                circuits[static_cast<size_t>(our_circuit)];
        const std::vector<int32_t> &theirs =
                circuits[static_cast<size_t>(their_circuit)];
        if (ours.size() != theirs.size()) {
            return false;
        }
        for (size_t position = 0; position < ours.size(); ++position) {
            const Node &one = nodes[static_cast<size_t>(ours[position])];
            const Node &two = nodes[static_cast<size_t>(theirs[position])];
            if (one.kind != two.kind || one.width != two.width
                || one.overflow != two.overflow
                || one.condition != two.condition
                || sinks_fed[static_cast<size_t>(ours[position])]
                           != sinks_fed[static_cast<size_t>(
                                   theirs[position])]) {
                return false;
            }
            switch (one.kind) {
            case Kind::constant:
            case Kind::offset:
            case Kind::shift:
            case Kind::through:
                if (one.value != two.value) {
                    return false;
                }
                break;
            case Kind::pointer:
                if (graph.target_sets_[static_cast<size_t>(one.value)]
                    != graph.target_sets_[static_cast<size_t>(two.value)]) {
                    return false;
                }
                break;
            case Kind::delay:
                if (!corresponds(one.value, two.value, our_circuit,
                                 their_circuit)) {
                    return false;
                }
                break;
            default:
                break;
            }
            const auto our_wires = operands(one), their_wires = operands(two);
            for (size_t slot = 0; slot < our_wires.size(); ++slot) {
                if (!corresponds(our_wires[slot].node, their_wires[slot].node,
                                 our_circuit, their_circuit)) {
                    return false;
                }
            }
            if ((one.record == none) != (two.record == none)) {
                return false;
            }
            if (one.record != none
                && !records_correspond(outermost(one.record),
                                       outermost(two.record), our_circuit,
                                       their_circuit)) {
                return false;
            }
        }
        return true;
    }

    bool has_operator(int32_t index) const {
        const std::vector<int32_t> &members =
                circuits[static_cast<size_t>(index)];
        return std::any_of(members.begin(), members.end(), [&](int32_t at) {
            return nodes[static_cast<size_t>(at)].is_operator();
        });
    }

    void find_shapes() {
        // the candidates: closed circuits with the same colours
        std::map<std::vector<uint64_t>, std::vector<int32_t>> alike;
        for (size_t index = 0; index < circuits.size(); ++index) {
            if (!has_operator(static_cast<int32_t>(index))
                || !is_closed(static_cast<int32_t>(index))) {
                continue;
            }
            std::vector<uint64_t> colours;
            for (const int32_t at : circuits[index]) {
                colours.push_back(colour[static_cast<size_t>(at)]);
            }
            alike[std::move(colours)].push_back(static_cast<int32_t>(index));
        }
        for (auto &[colours, candidates] : alike) {
            // the first candidate and all that are of its shape, then the
            // first of those left over, until none is
            while (candidates.size() > 1) {
                std::vector<int32_t> others;
                Shape shape;
                for (const int32_t candidate : candidates) {
                    if (candidate == candidates.front()
                        || same_shape(candidates.front(), candidate)) {
                        shape.copies.push_back(
                                circuits[static_cast<size_t>(candidate)]);
                    } else {
                        others.push_back(candidate);
                    }
                }
                if (shape.copies.size() > 1) {
                    add(std::move(shape));
                }
                candidates = std::move(others);
            }
        }
    }

    void add(Shape shape) {
        for (size_t copy = 0; copy < shape.copies.size(); ++copy) {
            for (const int32_t at : shape.copies[copy]) {
                nodes[static_cast<size_t>(at)].shape =
                        static_cast<int32_t>(graph.shapes_.size());
                nodes[static_cast<size_t>(at)].copy =
                        static_cast<int32_t>(copy);
            }
        }
        graph.copy_sets_.push_back(
                {static_cast<int>(shape.copies.size()),
                 static_cast<int>(shape.copies.front().size())});
        graph.shapes_.push_back(std::move(shape));
    }

    void run() {
        graph.shapes_.clear();
        graph.copy_sets_.clear();
        for (Node &each : nodes) {
            each.shape = each.copy = each.position = none;
        }
        find_readers();
        find_colours();
        find_circuits();
        find_shapes();
    }
};

// ---- build() ------------------------------------------------------------------------

struct DspGraph::Lowering {
    using Kind = Node::Kind;

    // An operand of an instruction row, by what it names. How the row
    // reaches it is settled when the memory is laid out.
    struct Operand {
        enum class Reach : uint8_t {
            none,
            zero,
            immediate,
            word,         // a node's word; `second` is a dword's other word
            sink_pointer, // the word of a loop's element that points at its sinks
            pointed,      // a field of the record a pointer holds: its offset
            sink          // a sink word: its address
        };
        Reach reach = Reach::none;
        int value   = 0;
        int second  = 0;
    };
    using Reach = Operand::Reach;

    struct Instruction {
        Op op          = Op::nop;
        bool wide      = false;
        ASource a      = ASource::zero;
        Condition cond = Condition::always;
        Operand r, x, y;
        IndexRegister which = IndexRegister::j; // an IDX's
        int32_t group       = none;             // the index group it issues in
        bool is_idx         = false;            // the group's IDX
        bool sets_flags     = false;            // a CMP a SEL waits for
        int32_t compare     = none;             // a SEL's CMP
        int32_t loop        = none; // not a row: a whole loop among the rows
        int cycles          = 1;    // what it takes to issue
        int height          = 0;    // the longest way to the program's end
        std::vector<std::pair<int32_t, int>>
                behind; // (instruction, cycles): what it issues behind
    };

    // Instruction rows that are ordered among each other: the straight-line
    // code, or the body of a loop.
    struct Block {
        std::vector<Instruction> code;
        std::vector<int32_t> order; // an IDX may issue more than once
        int32_t sink_group = none;
    };

    // A shape whose copies are the elements of a vector loop. The body is
    // the first copy's rows; every copy's words lie in a record of one
    // layout, a stride apart.
    struct Loop : Block {
        int32_t shape = none;
        int count     = 0;
        int elements  = 0; // in the shortest round
        int rows      = 0; // of the body, the waits counted
        int stride    = 0;
        int base      = none; // the first copy's record
        // each word's offset in the record, by the position of its node
        std::vector<int> offset;
        std::vector<std::pair<int32_t, int>> records; // the first copy's
        int sink_block = 0;    // the size of a copy's block of sinks
        int sink_word  = none; // the offset of the word that points at it
        std::vector<int> sink_blocks; // each copy's
    };

    // The rows that use j while it holds one pointer, or a sink block's base.
    struct Group {
        int32_t loop = none; // the loop whose body it is in
        int32_t idx  = none;
        std::vector<int32_t> members;
        int32_t read = none;       // a pointer's: a read through it
        std::vector<int> may_hold; // every address the index can be
        bool sinks = false;
    };

    // What a row reads and writes of DMEM.
    struct Accesses {
        std::vector<int> reads, writes;
    };

    // A round of fewer elements hides none of a result's latency.
    static constexpr int fewest_looped = result_latency;
    // The largest power of two a loop can step by.
    static constexpr int widest_stride = (loop_stride_max + 1) / 2;

    DspGraph &graph;
    std::vector<Node> &nodes;
    const std::vector<bool> &kept_straight; // by shape: not to be looped
    Block straight;
    std::vector<Loop> loops;
    std::vector<int32_t> loop_of_shape;
    std::vector<Group> groups;
    std::map<std::pair<int32_t, int32_t>, int32_t>
            pointer_group; // (pointer, offset) → group
    std::map<std::vector<int>, IndexTargets> target_lists;
    Block *into       = &straight; // where emit() puts a row
    int32_t into_loop = none;
    int32_t high_idx  = none;
    int32_t outgrown  = none; // a shape whose copy does not fit a stride

    Lowering(DspGraph &graph, const std::vector<bool> &kept_straight)
        : graph(graph), nodes(graph.nodes_), kept_straight(kept_straight) {}

    Node &node(Wire wire) {
        return nodes[static_cast<size_t>(wire.node)];
    }
    const Node &node(Wire wire) const {
        return nodes[static_cast<size_t>(wire.node)];
    }
    static bool connected(Wire wire) {
        return wire.node != none;
    }
    int32_t storage_root(int32_t at) const {
        while (nodes[static_cast<size_t>(at)].storage != at) {
            at = nodes[static_cast<size_t>(at)].storage;
        }
        return at;
    }
    const RecordLayout &record(int32_t index) const {
        return graph.records_[static_cast<size_t>(index)];
    }
    int32_t loop_of(const Node &each) const {
        return each.shape == none
                       ? none
                       : loop_of_shape[static_cast<size_t>(each.shape)];
    }

    // ---- loops -----------------------------------------------------------------

    // Every field of a record, with the records inside it, and where it lies
    // when the record is at `address`.
    template <typename Visit>
    void for_each_field(int32_t index, int address, Visit visit) const {
        const RecordLayout &layout = record(index);
        for (size_t field = 0; field < layout.fields.size(); ++field) {
            const int at = address
                           + (layout.field_offset.empty()
                                      ? 0
                                      : layout.field_offset[field]);
            if (layout.fields[field].record.index != none) {
                for_each_field(layout.fields[field].record.index, at, visit);
            } else if (layout.fields[field].wire.node != none) {
                visit(layout.fields[field].wire.node, at);
            }
        }
    }

    // Whether a pointer of the shape can point at a record of the shape: an
    // element of a loop reads no word that another element writes.
    bool points_into_itself(int32_t shape) const {
        for (const int32_t at :
             graph.shapes_[static_cast<size_t>(shape)].copies.front()) {
            const Node &pointer = nodes[static_cast<size_t>(at)];
            if (pointer.kind != Kind::pointer) {
                continue;
            }
            for (const int32_t target :
                 graph.target_sets_[static_cast<size_t>(pointer.value)]) {
                bool inside = false;
                for_each_field(target, 0, [&](int32_t field, int) {
                    inside =
                            inside
                            || nodes[static_cast<size_t>(field)].shape == shape;
                });
                if (inside) {
                    return true;
                }
            }
        }
        return false;
    }

    // The sinks of each copy as a block of one layout: a power-of-two block
    // with every copy's sinks at the same offsets in it, so that the body
    // names an offset and the copy's pointer holds the block. False when the
    // copies' sinks do not lie so.
    bool find_sink_blocks(Loop &loop) const {
        std::vector<std::vector<std::pair<int32_t, int>>> sinks(
                static_cast<size_t>(loop.count)); // (position, address)
        for (const auto &[address, value] : graph.sinks_) {
            if (node(value).shape == loop.shape) {
                sinks[static_cast<size_t>(node(value).copy)].push_back(
                        {node(value).position, address});
            }
        }
        for (auto &each : sinks) {
            std::stable_sort(each.begin(), each.end(),
                             [](const auto &one, const auto &other) {
                                 return one.first < other.first;
                             });
        }
        if (sinks.front().empty()) {
            return true;
        }
        for (int block = 1; block <= sink_count; block *= 2) {
            bool fits = true;
            loop.sink_blocks.clear();
            for (const auto &each : sinks) {
                const int base = each.front().second & ~(block - 1);
                loop.sink_blocks.push_back(base);
                for (size_t at = 0; fits && at < each.size(); ++at) {
                    fits = (each[at].second & ~(block - 1)) == base
                           && (each[at].second & (block - 1))
                                      == (sinks.front()[at].second
                                          & (block - 1));
                }
            }
            if (fits) {
                loop.sink_block = block;
                return true;
            }
        }
        return false;
    }

    void choose_loops() {
        loop_of_shape.assign(graph.shapes_.size(), none);
        for (size_t index = 0; index < graph.shapes_.size(); ++index) {
            Loop loop;
            loop.shape = static_cast<int32_t>(index);
            loop.count = static_cast<int>(graph.shapes_[index].copies.size());
            // The rounds are of sixteen and the last of what is left. The
            // builder spaces a body for the first round (#489), so a loop
            // here is of one round or of whole rounds.
            loop.elements = std::min(loop.count, vector_round);
            if (kept_straight[index] || loop.count < fewest_looped
                || loop.count > loop_count_max
                || (loop.count > vector_round && loop.count % vector_round != 0)
                || points_into_itself(loop.shape) || !find_sink_blocks(loop)) {
                continue;
            }
            loop_of_shape[index] = static_cast<int32_t>(loops.size());
            loops.push_back(std::move(loop));
        }
        for (size_t index = 0; index < graph.shapes_.size(); ++index) {
            graph.copy_sets_[index].looped = loop_of_shape[index] != none;
        }
    }

    // ---- storage -------------------------------------------------------------

    // The pointer groups, and the reads through a pointer that cannot issue
    // while j holds it: each of those is fetched into a word first.
    void find_groups_and_fetches() {
        for (Node &each : nodes) {
            each.readers = 0;
            each.delayed = false;
            each.fetched = false;
            each.group   = none;
        }
        for (Node &each : nodes) {
            for (const Wire wire : {each.a, each.x, each.y, each.b}) {
                if (connected(wire)) {
                    ++node(wire).readers;
                }
            }
            if (each.kind == Kind::delay && each.value != none) {
                nodes[static_cast<size_t>(each.value)].delayed = true;
            }
            if (each.kind == Kind::through) {
                const auto key = std::make_pair(each.a.node, each.x.node);
                if (!pointer_group.contains(key)) {
                    pointer_group[key] = static_cast<int32_t>(groups.size());
                    groups.push_back({});
                }
                each.group = pointer_group[key];
            }
        }
        // the groups each output depends on in this pass
        const size_t words = (groups.size() + 63) / 64;
        std::vector<std::vector<uint64_t>> depends(
                nodes.size(), std::vector<uint64_t>(words, 0));
        auto add_wire = [&](std::vector<uint64_t> &to, Wire wire) {
            if (!connected(wire) || node(wire).kind == Kind::delay) {
                return;
            }
            const std::vector<uint64_t> &from =
                    depends[static_cast<size_t>(wire.node)];
            for (size_t w = 0; w < words; ++w) {
                to[w] |= from[w];
            }
            if (node(wire).kind == Kind::through) {
                const auto group = static_cast<size_t>(node(wire).group);
                to[group / 64] |= uint64_t{1} << (group % 64);
            }
        };
        for (size_t at = 0; at < nodes.size(); ++at) {
            for (const Wire wire :
                 {nodes[at].a, nodes[at].x, nodes[at].y, nodes[at].b}) {
                add_wire(depends[at], wire);
            }
        }
        auto fetch = [&](Wire wire) {
            if (connected(wire) && node(wire).kind == Kind::through) {
                node(wire).fetched = true;
            }
        };
        // An instruction row reads through one pointer: of two fields behind
        // two pointers, the second is fetched. The group the row is of.
        auto one_group = [&](Wire first, Wire second) {
            int32_t group = none;
            for (const Wire wire : {first, second}) {
                if (!connected(wire) || node(wire).kind != Kind::through
                    || node(wire).fetched) {
                    continue;
                }
                if (group != none && node(wire).group != group) {
                    fetch(wire);
                    continue;
                }
                group = node(wire).group;
            }
            return group;
        };
        // Straight-line code has one j, and every pointer's rows take their
        // turn with it: there a field with several readers is fetched once
        // and costs one cycle of j, not one for each reader. An element of a
        // loop has a j of its own, and reads through it.
        for (Node &each : nodes) {
            each.fetched = each.kind == Kind::through && each.readers > 1
                           && loop_of(each) == none;
        }
        for (size_t at = 0; at < nodes.size(); ++at) {
            Node &reader      = nodes[at];
            const bool looped = loop_of(reader) != none;
            switch (reader.kind) {
            case Kind::through: // a pointer or an offset read through a pointer
                fetch(reader.a);
                fetch(reader.x);
                continue;
            case Kind::delay: // its word is its input's
                if (reader.value != none) {
                    fetch(Wire{reader.value});
                }
                continue;
            case Kind::sum:
            case Kind::multiply_add:
            case Kind::shift:
                fetch(reader.a); // the operand worked on in place
                break;
            case Kind::select:
                if (looped) {
                    one_group(reader.x, reader.y); // the CMP
                    one_group(reader.a, reader.b); // the SEL
                    continue;
                }
                // neither the CMP nor the SEL holds j: the flags are waited
                // for with the index free for others
                fetch(reader.x);
                fetch(reader.y);
                fetch(reader.a);
                fetch(reader.b);
                break;
            default:
                break;
            }
            if (!reader.is_operator()) {
                continue;
            }
            const int32_t group = one_group(reader.x, reader.y);
            if (group == none || looped) {
                continue;
            }
            // in straight-line code nothing in a group waits for another
            // row of its own group, so that j is held no longer than its
            // rows take to issue
            std::vector<uint64_t> others(words, 0);
            for (const Wire wire : {reader.a, reader.x, reader.y, reader.b}) {
                if (connected(wire) && node(wire).kind == Kind::through
                    && node(wire).group == group && !node(wire).fetched) {
                    continue;
                }
                add_wire(others, wire);
            }
            if (others[static_cast<size_t>(group) / 64]
                & (uint64_t{1} << (group % 64))) {
                fetch(reader.x);
                fetch(reader.y);
            }
        }
        for (const auto &[address, value] : graph.sinks_) {
            if (node(value).kind == Kind::delay) {
                graph.issue("a sink takes a value of this pass, not a delay's");
            }
            fetch(value);
        }
    }

    // Whether `taker`, an operator, can work in place on the word of its
    // operand a: a's output is read by nothing else, and neither is read by
    // a delay, which needs its word untouched until its own row.
    bool takes_word_of(const Node &taker, int32_t a) {
        const Node &given   = nodes[static_cast<size_t>(a)];
        const bool has_word = given.is_operator()
                              || (given.kind == Kind::through && given.fetched);
        return has_word && given.readers == 1 && !given.delayed
               && !taker.delayed && given.width == taker.width
               && (given.record == none || taker.record == none);
    }

    void decide_storage() {
        std::map<int32_t, int> sinks_of;
        for (const auto &[address, value] : graph.sinks_) {
            ++sinks_of[value.node];
        }
        for (size_t at = 0; at < nodes.size(); ++at) {
            Node &each             = nodes[at];
            each.storage           = static_cast<int32_t>(at);
            each.in_place          = false;
            each.copies_a          = false;
            each.sink              = none;
            const bool accumulates = each.kind == Kind::sum
                                     || each.kind == Kind::multiply_add
                                     || each.kind == Kind::shift;
            if (accumulates && connected(each.a)) {
                const Node &a = node(each.a);
                if (a.kind == Kind::delay
                    && a.value == static_cast<int32_t>(at)) {
                    each.in_place = true; // its own delayed output
                } else if (takes_word_of(each, each.a.node)) {
                    each.in_place = true;
                    each.storage  = each.a.node;
                } else if (each.kind == Kind::sum
                           && each.overflow == Overflow::saturate
                           && !connected(each.y) && each.width == Width::word) {
                    // a + x from zero: no word of a's is needed
                    each.y = each.x;
                    each.x = each.a;
                    each.a = {};
                } else if (each.width == Width::word) {
                    each.copies_a = true;
                } else {
                    graph.issue(
                            "a dword operator works in place: on its own delayed output, or on an output nothing else reads");
                }
            }
        }
        for (size_t at = 0; at < nodes.size(); ++at) {
            Node &each = nodes[at];
            if (each.kind == Kind::delay) {
                if (each.value == none) {
                    graph.issue("a delay without an input");
                    continue;
                }
                const Node &input = nodes[static_cast<size_t>(each.value)];
                if (!input.is_operator() && input.kind != Kind::through) {
                    graph.issue(
                            "a delay's input is an operator's output or a read through a pointer");
                }
                each.storage = each.value;
            }
        }
        // an operator nothing reads but one sink writes that sink itself
        for (const auto &[address, value] : graph.sinks_) {
            Node &each           = node(value);
            const bool from_zero = !each.in_place && !each.copies_a;
            // its row issues with the sinks, with j taken: too late for a
            // delay's value where the sinks come last
            bool pointed = false;
            for (const Wire wire : {each.a, each.x, each.y, each.b}) {
                pointed = pointed
                          || (connected(wire)
                              && (node(wire).kind == Kind::delay
                                  || (node(wire).kind == Kind::through
                                      && !node(wire).fetched)));
            }
            // (not a select: its SEL would wait for the sinks' turn with the flags held)
            if (each.is_operator() && each.kind != Kind::select && from_zero
                && !pointed && each.readers == 0 && !each.delayed
                && sinks_of[value.node] == 1 && each.record == none
                && each.width == Width::word
                && storage_root(value.node) == value.node) {
                each.sink = address;
            }
        }
    }

    // ---- records -----------------------------------------------------------------

    void lay_record(int32_t index) {
        RecordLayout &layout = graph.records_[static_cast<size_t>(index)];
        layout.field_offset.clear();
        int at = 0;
        for (const Field &field : layout.fields) {
            if (field.record.index != none) {
                lay_record(field.record.index);
                RecordLayout &inner =
                        graph.records_[static_cast<size_t>(field.record.index)];
                at           = aligned(at, inner.alignment);
                inner.offset = at;
                layout.field_offset.push_back(at);
                at += inner.size;
            } else {
                const bool dword = node(field.wire).width == Width::dword;
                at               = aligned(at, dword ? 2 : 1);
                layout.field_offset.push_back(at);
                at += dword ? 2 : 1;
            }
        }
        layout.size      = at;
        layout.alignment = power_of_two_at_least(at);
    }

    void lay_records() {
        for (size_t index = 0; index < graph.records_.size(); ++index) {
            if (graph.records_[index].parent == none) {
                lay_record(static_cast<int32_t>(index));
            }
        }
    }

    int32_t outermost(int32_t index) const {
        while (record(index).parent != none) {
            index = record(index).parent;
        }
        return index;
    }

    // ---- instructions -----------------------------------------------------------

    static Operand word_of(int32_t at, int second = 0) {
        return {Reach::word, at, second};
    }

    // The offset of a read through a pointer in the record j points at.
    int field_offset(const Node &read) const {
        const RecordLayout *layout = &record(
                graph.target_sets_[static_cast<size_t>(node(read.a).value)]
                        .front());
        if (connected(read.x)) {
            for (const Field &inside : layout->fields) {
                if (inside.record.index != none) {
                    layout = &record(inside.record.index);
                    break;
                }
            }
        }
        return layout->field_offset[static_cast<size_t>(read.value)];
    }

    // A wire as an operand; `group` takes the pointer group of a read through j.
    Operand operand(Wire wire, int32_t &group) const {
        if (!connected(wire)) {
            return {Reach::zero, 0};
        }
        const Node &from = node(wire);
        switch (from.kind) {
        case Kind::constant:
            return {Reach::immediate, from.value};
        case Kind::offset:
            return {Reach::immediate, record(from.value).offset};
        case Kind::through:
            if (!from.fetched) {
                group = from.group;
                return {Reach::pointed, field_offset(from)};
            }
            break;
        default:
            break;
        }
        return word_of(wire.node);
    }

    // Where the rows of a node go: the body of its loop if it is of the
    // loop's first copy, the straight-line code if it is of no loop. False
    // for the other copies, which the body's rows are for as well.
    bool enter(const Node &each) {
        into_loop = loop_of(each);
        into      = into_loop == none ? &straight
                                      : &loops[static_cast<size_t>(into_loop)];
        return into_loop == none || each.copy == 0;
    }

    int32_t emit(Instruction instruction) {
        const auto at = static_cast<int32_t>(into->code.size());
        if (instruction.group != none && !instruction.is_idx) {
            groups[static_cast<size_t>(instruction.group)].members.push_back(
                    at);
        }
        into->code.push_back(std::move(instruction));
        return at;
    }

    // The IDX of a pointer's group, before the group's first member.
    void open_group(int32_t group, int32_t read) {
        if (groups[static_cast<size_t>(group)].idx != none) {
            return;
        }
        Instruction idx;
        idx.op           = Op::idx;
        idx.is_idx       = true;
        idx.group        = group;
        int32_t no_group = none;
        idx.x         = operand(nodes[static_cast<size_t>(read)].a, no_group);
        idx.y         = operand(nodes[static_cast<size_t>(read)].x, no_group);
        Group &opened = groups[static_cast<size_t>(group)];
        opened.loop   = into_loop;
        opened.read   = read;
        opened.idx    = emit(idx);
    }

    // The group of the rows that write sinks, and its IDX: j ← the sink
    // area in straight-line code, the element's block of sinks in a loop.
    int32_t sinks_group() {
        if (into->sink_group == none) {
            into->sink_group = static_cast<int32_t>(groups.size());
            Group sinks;
            sinks.sinks = true;
            sinks.loop  = into_loop;
            groups.push_back(sinks);
            Instruction idx;
            idx.op     = Op::idx;
            idx.is_idx = true;
            idx.group  = into->sink_group;
            idx.x = into_loop == none ? Operand{Reach::immediate, sink_base}
                                      : Operand{Reach::sink_pointer, 0};
            idx.y = {Reach::zero, 0};
            const int32_t at                                  = emit(idx);
            groups[static_cast<size_t>(into->sink_group)].idx = at;
        }
        return into->sink_group;
    }

    // An arithmetic row; its group is its operands' pointer, or the sinks'.
    int32_t arithmetic(Op op, Operand r, ASource a, Wire x, Wire y,
                       bool wide = false) {
        Instruction row;
        row.op   = op;
        row.r    = r;
        row.a    = a;
        row.wide = wide;
        row.x    = operand(x, row.group);
        row.y    = operand(y, row.group);
        if (row.x.reach == Reach::immediate && row.y.reach == Reach::immediate
            && row.x.value != row.y.value) {
            graph.issue("an operator takes one constant, not two");
        }
        if (row.group != none) {
            const Wire through = connected(x) && node(x).kind == Kind::through
                                                 && !node(x).fetched
                                         ? x
                                         : y;
            open_group(row.group, through.node);
        }
        if (r.reach == Reach::sink) {
            row.group = sinks_group();
        }
        return emit(row);
    }

    // A word copied: to ← from.
    void copy(Operand to, Operand from, int32_t group) {
        Instruction row;
        row.op    = Op::add3;
        row.r     = to;
        row.x     = from;
        row.y     = {Reach::zero, 0};
        row.group = group;
        emit(row);
    }

    void lower(int32_t at) {
        const Node &each = nodes[static_cast<size_t>(at)];
        const bool wide  = each.width == Width::dword;
        const Operand r  = each.sink != none ? Operand{Reach::sink, each.sink}
                                             : word_of(at);
        if (each.kind == Kind::through) {
            if (!each.fetched) {
                return;
            }
            open_group(each.group, at);
            const int offset = field_offset(each);
            copy(r, {Reach::pointed, offset}, each.group);
            if (wide) { // a dword is fetched as its two words
                copy(word_of(at, 1), {Reach::pointed, offset + 1}, each.group);
            }
            return;
        }
        if (!each.is_operator()) {
            return;
        }
        if (each.copies_a) {
            int32_t group = none;
            copy(r, operand(each.a, group), none);
        }
        const ASource a = each.in_place || each.copies_a ? ASource::result
                                                         : ASource::zero;
        switch (each.kind) {
        case Kind::sum:
            if (each.overflow == Overflow::wrap) {
                if (connected(each.y)) {
                    graph.issue("a wrapping sum has two operands");
                }
                // a + 1.0 × x: MACW is the operation that wraps
                Instruction row;
                row.op   = Op::macw;
                row.r    = r;
                row.a    = a;
                row.wide = wide;
                row.x    = {Reach::immediate, word_one};
                row.y    = operand(each.x, row.group);
                if (row.group != none) {
                    open_group(row.group, each.x.node);
                }
                emit(row);
            } else {
                arithmetic(Op::add3, r, a, each.x, each.y, wide);
            }
            break;
        case Kind::multiply_add:
            arithmetic(each.overflow == Overflow::wrap ? Op::macw : Op::mac, r,
                       a, each.x, each.y, wide);
            break;
        case Kind::difference:
            arithmetic(Op::sub, r, ASource::zero, each.x, each.y);
            break;
        case Kind::absolute:
            arithmetic(Op::abs, r, ASource::zero, each.x, {});
            break;
        case Kind::maximum:
            arithmetic(Op::max, r, ASource::zero, each.x, each.y);
            break;
        case Kind::minimum:
            arithmetic(Op::min, r, ASource::zero, each.x, each.y);
            break;
        case Kind::shift: {
            Instruction row;
            row.op   = Op::shift;
            row.r    = r;
            row.a    = ASource::result;
            row.wide = wide;
            row.y    = {Reach::immediate, each.value};
            emit(row);
            break;
        }
        case Kind::select: {
            const int32_t compare = arithmetic(Op::cmp, {Reach::zero, 0},
                                               ASource::zero, each.x, each.y);
            into->code[static_cast<size_t>(compare)].sets_flags = true;
            const int32_t select =
                    arithmetic(Op::sel, r, ASource::zero, each.a, each.b);
            into->code[static_cast<size_t>(select)].cond    = each.condition;
            into->code[static_cast<size_t>(select)].compare = compare;
            break;
        }
        default:
            break;
        }
    }

    void lower_all() {
        for (size_t at = 0; at < nodes.size(); ++at) {
            // a delayed output is read before the row that renews it
            for (const Wire wire :
                 {nodes[at].a, nodes[at].x, nodes[at].y, nodes[at].b}) {
                if (connected(wire) && node(wire).kind == Kind::delay
                    && node(wire).value < static_cast<int32_t>(at)
                    && nodes[at].kind != Kind::delay) {
                    graph.issue(
                            "a delay's output is read by a node made after the delay's input: make the reader first");
                }
            }
            if (enter(nodes[at])) {
                lower(static_cast<int32_t>(at));
            }
        }
        // the sinks no operator writes itself are copies
        for (const auto &[address, value] : graph.sinks_) {
            if (node(value).sink != none || !enter(node(value))) {
                continue;
            }
            Instruction row; // sink ← value × 1.0
            row.op        = Op::mac;
            row.r         = {Reach::sink, address};
            int32_t group = none;
            row.x         = operand(value, group);
            row.y         = {Reach::immediate, word_one};
            row.group     = sinks_group();
            emit(row);
        }
    }

    // ---- dependencies -------------------------------------------------------------

    static bool writes_a_word(Op op) {
        return op == Op::mac || op == Op::macw || op == Op::add3
               || op == Op::cmp || op == Op::sub || op == Op::abs
               || op == Op::min || op == Op::max || op == Op::sel
               || op == Op::shift;
    }

    static void put_behind(Instruction &row, int32_t other, int cycles) {
        for (auto &[earlier, least] : row.behind) {
            if (earlier == other) {
                least = std::max(least, cycles);
                return;
            }
        }
        row.behind.push_back({other, cycles});
    }

    // What each row reads and writes, and the order that follows from it:
    // a row behind the last writer of what it reads by a result's latency,
    // and a writer behind every reader of the word as it was. `words` says
    // which words an operand names, as numbers of its own choosing.
    template <typename Words>
    std::vector<Accesses> find_word_dependencies(Block &block, Words words) {
        std::vector<Accesses> accesses(block.code.size());
        std::map<int, int32_t> last_writer;
        std::map<int, std::vector<int32_t>> readers;
        for (int32_t at = 0; at < static_cast<int32_t>(block.code.size());
             ++at) {
            Instruction &row         = block.code[static_cast<size_t>(at)];
            std::vector<int> &reads  = accesses[static_cast<size_t>(at)].reads;
            std::vector<int> &writes = accesses[static_cast<size_t>(at)].writes;
            if (row.op != Op::shift) {
                words(row, row.x, false, reads);
            }
            if (row.op != Op::abs) {
                words(row, row.y, row.wide && row.op != Op::shift, reads);
            }
            if (writes_a_word(row.op)) {
                if (row.a == ASource::result) {
                    words(row, row.r, row.wide, reads);
                }
                if (row.r.reach == Reach::word) {
                    words(row, row.r, row.wide, writes);
                }
            }
            std::map<int32_t, int> behind;
            auto after = [&](int32_t other, int cycles) {
                if (other != at) {
                    behind[other] = std::max(behind[other], cycles);
                }
            };
            for (const int word : reads) {
                if (last_writer.contains(word)) {
                    after(last_writer[word], result_latency);
                }
            }
            for (const int word : writes) {
                // behind every reader of the word as it was, and its writer
                for (const int32_t reader : readers[word]) {
                    after(reader, 1);
                }
                if (last_writer.contains(word)) {
                    after(last_writer[word], 1);
                }
            }
            for (const int word : reads) {
                readers[word].push_back(at);
            }
            for (const int word : writes) {
                readers[word].clear();
                last_writer[word] = at;
            }
            if (row.compare != none) {
                after(row.compare, state_latency);
            }
            row.behind.assign(behind.begin(), behind.end());
        }
        return accesses;
    }

    // The longest way from each row to the end of its block.
    static void find_heights(Block &block) {
        for (Instruction &row : block.code) {
            row.height = row.cycles - 1;
        }
        // most rows are behind rows made before them: a pass from the end
        // settles those, and the passes after it the few that are not
        bool raised = true;
        for (size_t pass = 0; raised && pass < block.code.size(); ++pass) {
            raised = false;
            for (auto at = static_cast<int32_t>(block.code.size()) - 1; at >= 0;
                 --at) {
                const Instruction &row = block.code[static_cast<size_t>(at)];
                for (const auto &[other, cycles] : row.behind) {
                    Instruction &earlier =
                            block.code[static_cast<size_t>(other)];
                    const int height = row.height + cycles + earlier.cycles - 1;
                    if (earlier.height < height) {
                        earlier.height = height;
                        raised         = true;
                    }
                }
            }
        }
    }

    // ---- a loop's body -------------------------------------------------------------

    // The words of the loop's own copy that an operand names, each as twice
    // its node and one more for a dword's other word. What a body reads of
    // other shapes and of straight-line code is written before the loop.
    void own_words(const Loop &loop, const Operand &operand, bool pair,
                   std::vector<int> &found) const {
        if (operand.reach != Reach::word) {
            return;
        }
        const int32_t root = storage_root(operand.value);
        if (nodes[static_cast<size_t>(root)].shape != loop.shape) {
            return;
        }
        found.push_back(root * 2 + operand.second);
        if (pair) {
            found.push_back(root * 2 + 1);
        }
    }

    // The body's rows in the order they issue, a row of the body at a time.
    // An element's rows are a round apart, so a latency of cycles is one of
    // rows: a round of sixteen hides them all. Every row that may issue is a
    // candidate: first the SEL the flags wait for, then the rows that read
    // through the pointer j holds, then the others by their height. When
    // none may, j goes to the pointer whose rows can go on: its IDX issues,
    // again if j was another's in between.
    void order_body(Loop &loop) {
        std::vector<Instruction> &code = loop.code;
        const auto count               = static_cast<int32_t>(code.size());
        auto rows_for                  = [&](int cycles) {
            return (cycles + loop.elements - 1) / loop.elements;
        };
        std::vector<int> issued_at(static_cast<size_t>(count), -1);
        auto may_issue = [&](const Instruction &row, int by) {
            for (const auto &[other, cycles] : row.behind) {
                const int at = issued_at[static_cast<size_t>(other)];
                if (at < 0 || at + rows_for(cycles) > by) {
                    return false;
                }
            }
            return true;
        };
        int left = 0;
        for (const Instruction &row : code) {
            left += row.is_idx ? 0 : 1;
        }
        int32_t open_group = none, open_compare = none;
        int index_lands = 0, at_row = 0, idle = 0;
        while (left > 0) {
            int32_t best = none, best_rank = 99, best_height = -1;
            int32_t next_group = none, next_height = -1;
            bool index_awaited = false;
            for (int32_t at = 0; at < count; ++at) {
                const Instruction &row = code[static_cast<size_t>(at)];
                if (row.is_idx || issued_at[static_cast<size_t>(at)] >= 0
                    || !may_issue(row, at_row)
                    || (row.sets_flags && open_compare != none)) {
                    continue;
                }
                if (row.group != none && row.group != open_group) {
                    const Instruction &idx = code[static_cast<size_t>(
                            groups[static_cast<size_t>(row.group)].idx)];
                    if (may_issue(idx, at_row) && row.height > next_height) {
                        next_group  = row.group;
                        next_height = row.height;
                    }
                    continue;
                }
                if (row.group != none && at_row < index_lands) {
                    index_awaited = true;
                    continue;
                }
                const int rank = row.compare != none ? 0
                                 : row.group != none ? 1
                                                     : 2;
                if (rank < best_rank
                    || (rank == best_rank && row.height > best_height)) {
                    best        = at;
                    best_rank   = rank;
                    best_height = row.height;
                }
            }
            if (best != none) {
                const Instruction &row = code[static_cast<size_t>(best)];
                issued_at[static_cast<size_t>(best)] = at_row++;
                loop.order.push_back(best);
                --left;
                idle = 0;
                if (row.sets_flags) {
                    open_compare = best;
                }
                if (row.compare != none) {
                    open_compare = none;
                }
            } else if (next_group != none && !index_awaited) {
                const int32_t idx = groups[static_cast<size_t>(next_group)].idx;
                loop.order.push_back(idx);
                issued_at[static_cast<size_t>(idx)] = at_row;
                open_group                          = next_group;
                index_lands = at_row++ + rows_for(index_latency);
                idle        = 0;
            } else if (++idle > result_latency) {
                graph.issue("a loop's body cannot be ordered");
                return;
            } else {
                ++at_row; // a wait, which the builder lays
            }
        }
        loop.rows = at_row;
    }

    // The record of a copy: the records the top made of its fields, the
    // words that last from pass to pass, and the words a value lives in
    // from the row that writes it to the last row that reads it, which the
    // values of other rows have before and after. False when the record
    // outgrows the widest stride.
    bool lay_element(Loop &loop, const std::vector<Accesses> &accesses) {
        const std::vector<int32_t> &pattern =
                graph.shapes_[static_cast<size_t>(loop.shape)].copies.front();
        loop.offset.assign(pattern.size(), none);
        auto offset_of = [&](int32_t root) -> int & {
            return loop.offset[static_cast<size_t>(
                    nodes[static_cast<size_t>(root)].position)];
        };
        int size = 0;
        // the records, the largest first: each is aligned to its size
        std::vector<int32_t> records;
        for (const int32_t at : pattern) {
            const Node &each = nodes[static_cast<size_t>(at)];
            if (each.record != none
                && std::find(records.begin(), records.end(),
                             outermost(each.record))
                           == records.end()) {
                records.push_back(outermost(each.record));
            }
        }
        std::stable_sort(records.begin(), records.end(),
                         [&](int32_t one, int32_t other) {
                             return record(one).alignment
                                    > record(other).alignment;
                         });
        for (const int32_t index : records) {
            size = aligned(size, record(index).alignment);
            loop.records.push_back({index, size});
            for_each_field(index, size, [&](int32_t field, int at) {
                offset_of(storage_root(field)) = at;
            });
            size += record(index).size;
        }
        // which words last: the firmware's, and those a delay reads
        std::vector<bool> lasts(pattern.size(), false);
        for (const int32_t at : pattern) {
            const Node &each = nodes[static_cast<size_t>(at)];
            if (each.kind == Kind::source || each.kind == Kind::pointer
                || each.delayed) {
                lasts[static_cast<size_t>(
                        nodes[static_cast<size_t>(storage_root(at))]
                                .position)] = true;
            }
        }
        // from which row to which each of the others is alive
        struct Life {
            int first = -1, last = -1;
        };
        std::map<int32_t, Life> lives; // by the word's node
        for (size_t at = 0; at < loop.order.size(); ++at) {
            const Accesses &touched =
                    accesses[static_cast<size_t>(loop.order[at])];
            for (const std::vector<int> *words :
                 {&touched.writes, &touched.reads}) {
                for (const int word : *words) {
                    Life &life = lives[word / 2];
                    life.first =
                            life.first < 0 ? static_cast<int>(at) : life.first;
                    life.last = static_cast<int>(at);
                }
            }
        }
        struct Slot {
            int offset, free_from;
        };
        std::vector<Slot> slots[2]; // of words, of dwords
        std::vector<std::pair<int, int32_t>> by_first_row;
        for (const int32_t at : pattern) {
            const Node &each = nodes[static_cast<size_t>(at)];
            const bool has_word =
                    each.kind == Kind::source || each.kind == Kind::pointer
                    || (each.is_operator() && each.sink == none)
                    || (each.kind == Kind::through && each.fetched);
            if (!has_word || each.storage != at || offset_of(at) != none) {
                continue;
            }
            const int words = each.width == Width::dword ? 2 : 1;
            if (lasts[static_cast<size_t>(each.position)]
                || !lives.contains(at)) {
                size          = aligned(size, words);
                offset_of(at) = size;
                size += words;
            } else {
                by_first_row.push_back({lives[at].first, at});
            }
        }
        if (loop.sink_block != 0) {
            loop.sink_word = size++;
        }
        std::sort(by_first_row.begin(), by_first_row.end());
        for (const auto &[first, at] : by_first_row) {
            const int words =
                    nodes[static_cast<size_t>(at)].width == Width::dword ? 2
                                                                         : 1;
            std::vector<Slot> &pool = slots[words - 1];
            auto slot               = std::find_if(pool.begin(), pool.end(),
                                                   [&](const Slot &each) {
                                         return each.free_from <= first;
                                     });
            if (slot == pool.end()) {
                size = aligned(size, words);
                pool.push_back({size, 0});
                slot = pool.end() - 1;
                size += words;
            }
            offset_of(at)   = slot->offset;
            slot->free_from = lives[at].last;
        }
        loop.stride = power_of_two_at_least(size);
        return loop.stride <= widest_stride;
    }

    // ---- layout ----------------------------------------------------------------

    void place_record(int32_t index, int address) {
        graph.records_[static_cast<size_t>(index)].address = address;
        place_inner_records(index, address);
        for_each_field(index, address, [&](int32_t field, int at) {
            // the word of the field is the word of whatever shares it
            Node &root = nodes[static_cast<size_t>(storage_root(field))];
            if (root.address != none) {
                graph.issue(
                        "two fields of records share a word: an operator works in place on a field and is a field itself");
            }
            root.address = at;
        });
    }

    void place_inner_records(int32_t index, int address) {
        const RecordLayout &layout = record(index);
        for (size_t field = 0; field < layout.fields.size(); ++field) {
            const int32_t inner = layout.fields[field].record.index;
            if (inner != none) {
                graph.records_[static_cast<size_t>(inner)].address =
                        address + layout.field_offset[field];
                place_inner_records(inner,
                                    address + layout.field_offset[field]);
            }
        }
    }

    bool is_of_a_loop(int32_t index) const {
        bool looped = false;
        for_each_field(index, 0, [&](int32_t field, int) {
            looped = looped
                     || loop_of(nodes[static_cast<size_t>(field)]) != none;
        });
        return looped;
    }

    // The loops' records from the top of DMEM down, a block of copies each.
    // Returns where the lowest block begins.
    int lay_loops() {
        int ceiling = register_count;
        for (Loop &loop : loops) {
            const Shape &shape = graph.shapes_[static_cast<size_t>(loop.shape)];
            ceiling = (ceiling - loop.count * loop.stride) / loop.stride
                      * loop.stride;
            loop.base = ceiling;
            if (ceiling < direct_first) {
                graph.issue("the loops' records do not fit DMEM");
                return ceiling;
            }
            for (size_t copy = 0; copy < shape.copies.size(); ++copy) {
                const std::vector<int32_t> &members = shape.copies[copy];
                const int base =
                        loop.base + static_cast<int>(copy) * loop.stride;
                for (const auto &[first_copys, offset] : loop.records) {
                    // the copy's record: the one its node at the place of
                    // the first copy's field is a field of
                    int32_t position = none;
                    for_each_field(first_copys, 0, [&](int32_t field, int) {
                        position = position == none
                                           ? nodes[static_cast<size_t>(field)]
                                                     .position
                                           : position;
                    });
                    place_record(
                            outermost(nodes[static_cast<size_t>(
                                                    members[static_cast<size_t>(
                                                            position)])]
                                              .record),
                            base + offset);
                }
                for (size_t position = 0; position < members.size();
                     ++position) {
                    Node &each = nodes[static_cast<size_t>(members[position])];
                    if (loop.offset[position] != none && each.address == none) {
                        each.address = base + loop.offset[position];
                    }
                }
                if (loop.sink_word != none) {
                    graph.initial_values_.push_back(
                            {base + loop.sink_word, loop.sink_blocks[copy]});
                }
            }
        }
        return ceiling;
    }

    void lay_out() {
        for (Node &each : nodes) {
            each.address = none;
        }
        graph.initial_values_.clear();
        // Straight-line code reaches the lower half directly and the upper
        // half through i. With a loop in the program i is the loops', and
        // straight-line code has the lower half below the loops' records.
        const int ceiling = lay_loops();
        const bool upper  = loops.empty();
        int direct = direct_first, high = high_base;
        const int direct_end = std::min(high_base, ceiling);
        for (size_t index = 0; index < graph.records_.size(); ++index) {
            const RecordLayout &layout = graph.records_[index];
            if (layout.parent != none
                || is_of_a_loop(static_cast<int32_t>(index))) {
                continue;
            }
            int &at = upper ? high : direct;
            at      = aligned(at, layout.alignment);
            place_record(static_cast<int32_t>(index), at);
            at += layout.size;
        }
        for (size_t at = 0; at < nodes.size(); ++at) {
            Node &each = nodes[at];
            const bool has_word =
                    each.kind == Kind::source || each.kind == Kind::pointer
                    || (each.is_operator() && each.sink == none)
                    || (each.kind == Kind::through && each.fetched);
            if (!has_word || each.storage != static_cast<int32_t>(at)
                || each.address != none || loop_of(each) != none) {
                continue;
            }
            const int size = each.width == Width::dword ? 2 : 1;
            if (aligned(direct, size) + size <= direct_end || !upper) {
                direct       = aligned(direct, size);
                each.address = direct;
                direct += size;
            } else {
                high         = aligned(high, size);
                each.address = high;
                high += size;
            }
        }
        if (high > register_count) {
            graph.issue("the graph's words do not fit DMEM: "
                        + std::to_string(high - register_count) + " too many");
        }
        if (direct > direct_end) {
            graph.issue("the graph's words do not fit below "
                        + std::string(upper ? "DMEM's upper half"
                                            : "the loops' records")
                        + ": " + std::to_string(direct - direct_end)
                        + " too many");
        }
        std::fill(graph.writers_.begin(), graph.writers_.end(), Writer::nobody);
        for (size_t at = 0; at < nodes.size(); ++at) {
            Node &each = nodes[at];
            if (each.sink != none) {
                each.address = each.sink;
                continue;
            }
            const Node &root = nodes[static_cast<size_t>(
                    storage_root(static_cast<int32_t>(at)))];
            each.address     = root.address;
            if (each.address == none || each.address >= register_count) {
                continue;
            }
            const Writer writer =
                    each.kind == Kind::source || each.kind == Kind::pointer
                            ? Writer::firmware
                            : Writer::program;
            const int size = each.width == Width::dword ? 2 : 1;
            for (int word = 0; word < size; ++word) {
                Writer &slot = graph.writers_[static_cast<size_t>(each.address
                                                                  + word)];
                slot         = slot == Writer::program ? slot : writer;
            }
        }
        for (const InitialValue &initial : graph.initial_values_) {
            graph.writers_[static_cast<size_t>(initial.address)] =
                    Writer::firmware;
        }
    }

    // Every address each pointer's index can be, now that the records lie.
    void find_what_indexes_hold() {
        for (Group &group : groups) {
            if (group.sinks && group.loop != none) {
                group.may_hold =
                        loops[static_cast<size_t>(group.loop)].sink_blocks;
            }
            if (group.read == none) {
                continue;
            }
            const Node &read = nodes[static_cast<size_t>(group.read)];
            for (const int32_t target :
                 graph.target_sets_[static_cast<size_t>(node(read.a).value)]) {
                if (!connected(read.x)) {
                    group.may_hold.push_back(record(target).address);
                    continue;
                }
                for (const Field &field : record(target).fields) {
                    if (field.record.index != none) {
                        group.may_hold.push_back(
                                record(field.record.index).address);
                    }
                }
            }
        }
    }

    int address_of(const Operand &operand) const {
        return nodes[static_cast<size_t>(operand.value)].address
               + operand.second;
    }

    bool is_own(const Loop &loop, const Operand &operand) const {
        return operand.reach == Reach::word
               && nodes[static_cast<size_t>(storage_root(operand.value))].shape
                          == loop.shape;
    }

    bool reaches_high(const Instruction &row) const {
        for (const Operand *operand : {&row.r, &row.x, &row.y}) {
            if (operand->reach == Reach::word
                && address_of(*operand) >= high_base) {
                return true;
            }
        }
        return false;
    }

    // How the rows reach their words: a row of a loop's body reaches its
    // element's through the loop's index register, and anything else as a
    // direct operand; straight-line code reaches the upper half through i,
    // which it sets once, and has no i to set where there is a loop.
    void find_reach() {
        for (const Loop &loop : loops) {
            for (const Instruction &row : loop.code) {
                for (const Operand *operand : {&row.r, &row.x, &row.y}) {
                    if (operand->reach == Reach::word && !is_own(loop, *operand)
                        && address_of(*operand) >= direct_reach) {
                        graph.issue(
                                "a loop reads a word out of a direct operand's reach");
                        return;
                    }
                }
            }
        }
        if (std::none_of(straight.code.begin(), straight.code.end(),
                         [&](const Instruction &row) {
                             return reaches_high(row);
                         })) {
            return;
        }
        if (!loops.empty()) {
            graph.issue(
                    "straight-line code has words out of a direct operand's reach, and the loops have the index registers");
            return;
        }
        Instruction high; // i ← the upper half's base
        high.op    = Op::idx;
        high.which = IndexRegister::i;
        high.x     = {Reach::immediate, high_base};
        high.y     = {Reach::zero, 0};
        into       = &straight;
        into_loop  = none;
        high_idx   = emit(high);
    }

    // ---- the order of the program ----------------------------------------------------

    // The DMEM addresses an operand names: one, or one for each record a
    // pointer can hold; none for a sink, which nothing reads.
    void addresses(const Instruction &row, const Operand &operand, bool pair,
                   std::vector<int> &found) const {
        auto add = [&](int address) {
            found.push_back(address);
            if (pair) {
                found.push_back(address + 1);
            }
        };
        if (operand.reach == Reach::word) {
            add(address_of(operand));
        } else if (operand.reach == Reach::pointed) {
            for (const int base :
                 groups[static_cast<size_t>(row.group)].may_hold) {
                add(base | operand.value);
            }
        }
    }

    // A loop among the straight-line rows: one instruction that takes the
    // loop's cycles, reads what its body reads of others' words, and writes
    // its copies' records.
    void add_loops_to_the_rows(std::vector<Accesses> &accesses) {
        for (size_t index = 0; index < loops.size(); ++index) {
            const Loop &loop = loops[index];
            Instruction whole;
            whole.loop   = static_cast<int32_t>(index);
            whole.cycles = 2 + loop.rows * loop.count; // its row, a bubble
            Accesses touched;
            for (const Instruction &row : loop.code) {
                for (const Operand *operand : {&row.r, &row.x, &row.y}) {
                    if (!is_own(loop, *operand)) {
                        addresses(row, *operand, row.wide, touched.reads);
                    }
                }
            }
            for (int word = 0; word < loop.count * loop.stride; ++word) {
                touched.writes.push_back(loop.base + word);
            }
            straight.code.push_back(std::move(whole));
            accesses.push_back(std::move(touched));
        }
        // a loop behind the rows and loops that write what it reads, and
        // the readers of its copies' records behind it
        const auto count = static_cast<int32_t>(straight.code.size());
        for (int32_t at = 0; at < count; ++at) {
            const Instruction &row = straight.code[static_cast<size_t>(at)];
            if (row.loop == none) {
                continue;
            }
            const Loop &loop    = loops[static_cast<size_t>(row.loop)];
            auto in_its_records = [&](int address) {
                return address >= loop.base
                       && address < loop.base + loop.count * loop.stride;
            };
            const std::vector<int> &read =
                    accesses[static_cast<size_t>(at)].reads;
            for (int32_t other = 0; other < count; ++other) {
                if (other == at) {
                    continue;
                }
                const Accesses &theirs = accesses[static_cast<size_t>(other)];
                if (std::any_of(theirs.reads.begin(), theirs.reads.end(),
                                in_its_records)) {
                    put_behind(straight.code[static_cast<size_t>(other)], at,
                               result_latency);
                }
                if (straight.code[static_cast<size_t>(other)].loop == none
                    && std::any_of(theirs.writes.begin(), theirs.writes.end(),
                                   [&](int address) {
                                       return std::find(read.begin(),
                                                        read.end(), address)
                                              != read.end();
                                   })) {
                    put_behind(straight.code[static_cast<size_t>(at)], other,
                               result_latency);
                }
            }
        }
    }

    void find_dependencies() {
        std::vector<Accesses> accesses = find_word_dependencies(
                straight, [&](const Instruction &row, const Operand &operand,
                              bool pair, std::vector<int> &found) {
                    addresses(row, operand, pair, found);
                });
        add_loops_to_the_rows(accesses);
        const auto count = static_cast<int32_t>(straight.code.size());
        for (int32_t at = 0; at < count; ++at) {
            Instruction &row = straight.code[static_cast<size_t>(at)];
            if (high_idx != none && at != high_idx && reaches_high(row)) {
                put_behind(row, high_idx, index_latency);
            }
            if (row.group != none && !row.is_idx) {
                put_behind(row, groups[static_cast<size_t>(row.group)].idx,
                           index_latency);
            }
            if (row.is_idx && row.group == straight.sink_group) {
                // the sinks come last
                for (int32_t other = 0; other < count; ++other) {
                    if (straight.code[static_cast<size_t>(other)].group
                        != straight.sink_group) {
                        row.behind.push_back({other, 1});
                    }
                }
            }
        }
        find_heights(straight);
    }

    // A cycle at a time, the instruction that may issue and matters most:
    // a member of the group that has j, the SEL the flags wait for, an IDX
    // that opens a group whose members can follow at once, a CMP whose SEL
    // can, anything else by its height. A loop issues with j and the flags
    // free, and takes them and its cycles.
    void schedule() {
        const std::vector<Instruction> &code = straight.code;
        const auto count = static_cast<int32_t>(code.size());
        std::vector<int64_t> done_at(static_cast<size_t>(count), -1);
        int32_t open_group = none, open_compare = none;
        size_t members_left = 0;
        int64_t cycle       = 0;
        auto can_issue      = [&](const Instruction &row, int64_t by,
                             int32_t except) {
            for (const auto &[other, cycles] : row.behind) {
                if (other == except) {
                    continue;
                }
                const int64_t at = done_at[static_cast<size_t>(other)];
                if (at < 0 || at + cycles > by) {
                    return false;
                }
            }
            return true;
        };
        while (static_cast<int32_t>(straight.order.size()) < count) {
            int32_t best = none, best_rank = 99, best_height = -1;
            for (int32_t at = 0; at < count; ++at) {
                const Instruction &row = code[static_cast<size_t>(at)];
                if (done_at[static_cast<size_t>(at)] >= 0
                    || !can_issue(row, cycle, none)
                    || (row.loop != none
                        && (open_group != none || open_compare != none))) {
                    continue;
                }
                int rank = 4;
                if (row.is_idx && row.group != none) {
                    if (open_group != none) {
                        continue;
                    }
                    const Group &group = groups[static_cast<size_t>(row.group)];
                    bool ready         = true;
                    int64_t by         = cycle + index_latency;
                    for (const int32_t member : group.members) {
                        ready = ready
                                && (group.sinks
                                    || can_issue(
                                            code[static_cast<size_t>(member)],
                                            by++, at));
                    }
                    if (!ready) {
                        continue;
                    }
                    rank = 2;
                } else if (row.group != none) {
                    rank = 0;
                } else if (row.compare != none) {
                    rank = 1;
                }
                if (row.sets_flags) {
                    if (open_compare != none) {
                        continue;
                    }
                    bool ready = true; // its SEL can follow at once
                    for (int32_t select = at + 1; select < count; ++select) {
                        if (code[static_cast<size_t>(select)].compare == at) {
                            ready = can_issue(code[static_cast<size_t>(select)],
                                              cycle + state_latency, at);
                            break;
                        }
                    }
                    if (!ready) {
                        continue;
                    }
                    rank = std::min(rank, 3);
                }
                if (rank < best_rank
                    || (rank == best_rank && row.height > best_height)) {
                    best        = at;
                    best_rank   = rank;
                    best_height = row.height;
                }
            }
            if (best == none) {
                if (++cycle > 4 * pass_cycle_limit) {
                    graph.issue("the graph's instructions cannot be ordered");
                    return;
                }
                continue;
            }
            const Instruction &row = code[static_cast<size_t>(best)];
            cycle += row.cycles;
            done_at[static_cast<size_t>(best)] = cycle - 1;
            straight.order.push_back(best);
            if (row.is_idx && row.group != none) {
                open_group = row.group;
                members_left =
                        groups[static_cast<size_t>(row.group)].members.size();
                if (members_left == 0) {
                    open_group = none;
                }
            } else if (row.group != none && --members_left == 0) {
                open_group = none;
            }
            if (row.sets_flags) {
                open_compare = best;
            }
            if (row.compare != none) {
                open_compare = none;
            }
        }
    }

    // ---- emission ------------------------------------------------------------------------

    csp::Operand machine_operand(const Operand &operand,
                                 const Loop *loop) const {
        switch (operand.reach) {
        case Reach::word: {
            const int address = address_of(operand);
            if (loop && is_own(*loop, operand)) {
                return csp::Operand::indexed(IndexRegister::i,
                                             address - loop->base);
            }
            return address < direct_reach
                           ? csp::Operand::direct(address)
                           : csp::Operand::indexed(IndexRegister::i,
                                                   address - high_base);
        }
        case Reach::sink_pointer:
            return csp::Operand::indexed(IndexRegister::i, loop->sink_word);
        case Reach::pointed:
            return csp::Operand::indexed(IndexRegister::j, operand.value);
        case Reach::sink:
            return csp::Operand::indexed(
                    IndexRegister::j,
                    loop ? operand.value & (loop->sink_block - 1)
                         : operand.value - sink_base);
        case Reach::zero:
            return csp::Operand::direct(0);
        default:
            return csp::Operand::none();
        }
    }

    Source machine_source(const Operand &operand, const Loop *loop) const {
        return operand.reach == Reach::immediate
                       ? Source::imm(operand.value)
                       : Source::reg(machine_operand(operand, loop));
    }

    void emit_row(ProgramBuilder &program, const Instruction &row,
                  const Loop *loop) {
        const csp::Operand r = machine_operand(row.r, loop);
        const Source x       = machine_source(row.x, loop),
                     y       = machine_source(row.y, loop);
        switch (row.op) {
        case Op::mac:
            program.mac(r, row.a, x, y, row.wide);
            break;
        case Op::macw:
            program.macw(r, row.a, x, y, row.wide);
            break;
        case Op::add3:
            program.add3(r, row.a, x, y, row.wide);
            break;
        case Op::cmp:
            program.cmp(r, x, y);
            break;
        case Op::sub:
            program.sub(r, x, y);
            break;
        case Op::abs:
            program.abs(r, x);
            break;
        case Op::max:
            program.max(r, x, y);
            break;
        case Op::min:
            program.min(r, x, y);
            break;
        case Op::sel:
            program.sel(r, row.cond, x, y);
            break;
        case Op::shift:
            program.shift(r, row.a, y, row.wide);
            break;
        case Op::idx: {
            const std::vector<int> *may_hold =
                    row.group != none
                            ? &groups[static_cast<size_t>(row.group)].may_hold
                            : nullptr;
            if (may_hold && !may_hold->empty()) {
                if (!target_lists.contains(*may_hold)) {
                    target_lists[*may_hold] = program.targets(*may_hold);
                }
                program.idx(row.which, x, y, target_lists[*may_hold]);
            } else {
                program.idx(row.which, x, y);
            }
            break;
        }
        default:
            break;
        }
    }

    void emit_program(ProgramBuilder::Built &built) {
        // The program's rows, and before each loop the IDX that points i at
        // its first record: as many rows ahead as its index takes to land
        // and the rows there allow, which do not use i where there is a loop.
        struct Item {
            int32_t row       = none;
            int32_t loop      = none;
            bool points_index = false;
        };
        std::vector<Item> items;
        size_t after_last_loop = 0;
        for (const int32_t at : straight.order) {
            const int32_t loop = straight.code[static_cast<size_t>(at)].loop;
            if (loop == none) {
                items.push_back({at, none, false});
                continue;
            }
            const size_t ahead = static_cast<size_t>(index_latency - 1);
            items.insert(
                    items.begin()
                            + static_cast<std::ptrdiff_t>(std::max(
                                    after_last_loop,
                                    items.size()
                                            - std::min(items.size(), ahead))),
                    {none, loop, true});
            items.push_back({none, loop, false});
            after_last_loop = items.size();
        }
        ProgramBuilder program;
        for (const Item &item : items) {
            if (item.loop == none) {
                emit_row(program, straight.code[static_cast<size_t>(item.row)],
                         nullptr);
                continue;
            }
            const Loop &loop = loops[static_cast<size_t>(item.loop)];
            if (item.points_index) {
                program.idx(IndexRegister::i, Source::imm(loop.base),
                            Source::reg(csp::Operand::direct(0)));
                continue;
            }
            const size_t opened = program.open_loop(
                    IndexRegister::i, loop.count, loop.stride, true);
            for (const int32_t at : loop.order) {
                emit_row(program, loop.code[static_cast<size_t>(at)], &loop);
            }
            program.close_loop(opened);
        }
        program.build(built);
        for (const BuildIssue &found : built.issues) {
            if (found.error) {
                graph.issue(found.message);
            }
        }
    }

    // False with `outgrown` set when a shape's copy does not fit a loop's
    // stride: the build is run again with that shape kept straight-line.
    bool run(ProgramBuilder::Built &built) {
        choose_loops();
        find_groups_and_fetches();
        decide_storage();
        lay_records();
        if (!graph.issues_.empty()) {
            return false;
        }
        lower_all();
        if (!graph.issues_.empty()) {
            return false;
        }
        for (Loop &loop : loops) {
            const std::vector<Accesses> accesses = find_word_dependencies(
                    loop, [&](const Instruction &, const Operand &operand,
                              bool pair, std::vector<int> &found) {
                        own_words(loop, operand, pair, found);
                    });
            find_heights(loop);
            order_body(loop);
            if (!graph.issues_.empty()) {
                return false;
            }
            if (!lay_element(loop, accesses)) {
                outgrown = loop.shape;
                return false;
            }
        }
        lay_out();
        find_what_indexes_hold();
        find_reach();
        if (!graph.issues_.empty()) {
            return false;
        }
        find_dependencies();
        schedule();
        if (!graph.issues_.empty()) {
            return false;
        }
        emit_program(built);
        return built.ok && graph.issues_.empty();
    }
};

bool DspGraph::build(ProgramBuilder::Built &built) {
    Copies(*this).run();
    // a shape whose copy outgrows a loop's stride stays straight-line code
    std::vector<bool> kept_straight(shapes_.size(), false);
    for (;;) {
        Lowering lowering(*this, kept_straight);
        const bool built_it = lowering.run(built);
        if (lowering.outgrown == none) {
            return built_it;
        }
        kept_straight[static_cast<size_t>(lowering.outgrown)] = true;
    }
}

} // namespace csp
