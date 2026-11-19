// dsp_graph.cpp — the DSP graph laid out, ordered and emitted (see dsp_graph.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// build() works in steps, each a part of Lowering below:
//
//   storage       which reads through a pointer are fetched into a word of
//                 their own, and which operators work in place: one that
//                 accumulates onto an operand nothing else reads takes that
//                 operand's word, and a delay is its input's word;
//   layout        records into DMEM's upper half, every other word from the
//                 direct half up;
//   instructions  every node as the rows it takes, in the order the nodes
//                 were made, which is an order the values can be computed in;
//   dependencies  which instruction must issue how many cycles behind which,
//                 read off the addresses the instructions name;
//   order         a list scheduler: a cycle at a time, an instruction whose
//                 predecessors are far enough behind, j and the flags each
//                 with one user at a time;
//   emission      through csp::ProgramBuilder, which lays the waits that are
//                 left, proves the schedule and encodes.
//
// The index registers: i holds the upper half's base all program long, so
// an address there is an offset through i; j is each pointer's in turn, and
// the sink area's base for the rows that write sinks, which come last.

#include "dsp_graph.hpp"

#include <algorithm>
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
    Kind kind         = Kind::source;
    Width width       = Width::word;
    Overflow overflow = Overflow::saturate;
    Condition condition = Condition::always;
    Wire a, x, y, b;
    int32_t value  = none;
    int32_t record = none; // the record this output is a field of

    // what build() works out
    int32_t storage = none; // the node whose word the output lives in
    int32_t address = none;
    int32_t group   = none; // a read through a pointer: its pointer's group
    int32_t sink    = none; // the sink word the operator writes directly
    int readers     = 0;
    bool delayed    = false; // a delay reads it
    bool fetched    = false; // a read through a pointer, into its own word
    bool in_place   = false; // the operator works on a's word
    bool copies_a   = false; // a is copied into the output's word first

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
    node.width = a.node == none ? Width::word
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
    node.width = a.node == none ? Width::word
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
    if (address < sink_base || address >= sink_area_end
        || value.node == none) {
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

// ---- build() ------------------------------------------------------------------------

struct DspGraph::Lowering {
    using Kind = Node::Kind;

    // An operand of an instruction, by how it is reached.
    struct Operand {
        enum class Reach : uint8_t {
            none,
            zero,
            immediate,
            direct,  // DMEM's lower half: the address
            high,    // the upper half: the offset through i
            pointed, // a record's field: the offset through j
            sink     // a sink word: the offset through j
        };
        Reach reach = Reach::none;
        int value   = 0;
    };
    using Reach = Operand::Reach;

    struct Instruction {
        Op op          = Op::nop;
        bool wide      = false;
        ASource a      = ASource::zero;
        Condition cond = Condition::always;
        Operand r, x, y;
        IndexRegister which = IndexRegister::j; // an IDX's
        int32_t group       = none;  // the index group it issues in
        bool is_idx         = false; // the group's IDX
        bool sets_flags     = false; // a CMP a SEL waits for
        int32_t compare     = none;  // a SEL's CMP
        int height          = 0;     // the longest way to the program's end
        std::vector<std::pair<int32_t, int>>
                behind; // (instruction, cycles): what it issues behind
    };

    // The rows that use j while it holds one pointer, or the sinks' base.
    struct Group {
        int32_t idx = none;
        std::vector<int32_t> members;
        std::vector<int> may_hold; // a pointer's: every address it can be
        bool sinks = false;
    };

    DspGraph &graph;
    std::vector<Node> &nodes;
    std::vector<Instruction> code;
    std::vector<Group> groups;
    std::map<std::pair<int32_t, int32_t>, int32_t>
            pointer_group; // (pointer, offset) → group
    int32_t high_idx   = none;
    int32_t sink_group = none;
    int32_t body_end   = 0;
    std::vector<int32_t> order;

    explicit Lowering(DspGraph &graph) : graph(graph), nodes(graph.nodes_) {}

    Node &node(Wire wire) {
        return nodes[static_cast<size_t>(wire.node)];
    }
    static bool connected(Wire wire) {
        return wire.node != none;
    }
    int32_t storage_root(int32_t at) {
        while (nodes[static_cast<size_t>(at)].storage != at) {
            at = nodes[static_cast<size_t>(at)].storage;
        }
        return at;
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
        for (size_t at = 0; at < nodes.size(); ++at) {
            Node &reader = nodes[at];
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
            // one group an instruction, and nothing in it that waits for
            // another row of its own group
            int32_t group = none;
            for (const Wire wire : {reader.x, reader.y}) {
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
            if (group == none) {
                continue;
            }
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
        const Node &given = nodes[static_cast<size_t>(a)];
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
            Node &each    = nodes[at];
            each.storage  = static_cast<int32_t>(at);
            each.in_place = false;
            each.copies_a = false;
            each.sink     = none;
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
                           && !connected(each.y)
                           && each.width == Width::word) {
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
            bool pointed         = false;
            for (const Wire wire : {each.a, each.x, each.y, each.b}) {
                pointed = pointed
                          || (connected(wire)
                              && node(wire).kind == Kind::through
                              && !node(wire).fetched);
            }
            // (not a select: its SEL would wait for the sinks' turn with the flags held)
            if (each.is_operator() && each.kind != Kind::select && from_zero
                && !pointed
                && each.readers == 0 && !each.delayed
                && sinks_of[value.node] == 1 && each.record == none
                && each.width == Width::word
                && storage_root(value.node) == value.node) {
                each.sink = address;
            }
        }
    }

    // ---- layout ----------------------------------------------------------------

    void lay_record(int32_t index) {
        RecordLayout &record = graph.records_[static_cast<size_t>(index)];
        record.field_offset.clear();
        int at = 0;
        for (const Field &field : record.fields) {
            if (field.record.index != none) {
                lay_record(field.record.index);
                RecordLayout &inner =
                        graph.records_[static_cast<size_t>(field.record.index)];
                at           = aligned(at, inner.alignment);
                inner.offset = at;
                record.field_offset.push_back(at);
                at += inner.size;
            } else {
                const bool dword = node(field.wire).width == Width::dword;
                at               = aligned(at, dword ? 2 : 1);
                record.field_offset.push_back(at);
                at += dword ? 2 : 1;
            }
        }
        record.size      = at;
        record.alignment = power_of_two_at_least(at);
    }

    void place_record(int32_t index, int address) {
        RecordLayout &record = graph.records_[static_cast<size_t>(index)];
        record.address       = address;
        for (size_t f = 0; f < record.fields.size(); ++f) {
            const Field &field = record.fields[f];
            if (field.record.index != none) {
                place_record(field.record.index,
                             address + record.field_offset[f]);
            } else {
                // the word of the field is the word of whatever shares it
                Node &root = nodes[static_cast<size_t>(
                        storage_root(field.wire.node))];
                if (root.address != none) {
                    graph.issue(
                            "two fields of records share a word: an operator works in place on a field and is a field itself");
                }
                root.address = address + record.field_offset[f];
            }
        }
    }

    void lay_out() {
        for (Node &each : nodes) {
            each.address = none;
        }
        int high = high_base;
        for (size_t index = 0; index < graph.records_.size(); ++index) {
            if (graph.records_[index].parent != none) {
                continue;
            }
            lay_record(static_cast<int32_t>(index));
            high = aligned(high, graph.records_[index].alignment);
            place_record(static_cast<int32_t>(index), high);
            high += graph.records_[index].size;
        }
        int direct = direct_first;
        for (size_t at = 0; at < nodes.size(); ++at) {
            Node &each = nodes[at];
            const bool has_word =
                    each.kind == Kind::source || each.kind == Kind::pointer
                    || (each.is_operator() && each.sink == none)
                    || (each.kind == Kind::through && each.fetched);
            if (!has_word || each.storage != static_cast<int32_t>(at)
                || each.address != none) {
                continue;
            }
            const int size = each.width == Width::dword ? 2 : 1;
            if (aligned(direct, size) + size <= high_base) {
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
        std::fill(graph.writers_.begin(), graph.writers_.end(),
                  Writer::nobody);
        for (size_t at = 0; at < nodes.size(); ++at) {
            Node &each = nodes[at];
            if (each.sink != none) {
                each.address = each.sink;
                continue;
            }
            const Node &root =
                    nodes[static_cast<size_t>(storage_root(
                            static_cast<int32_t>(at)))];
            each.address = root.address;
            if (each.address == none || each.address >= register_count) {
                continue;
            }
            const Writer writer =
                    each.kind == Kind::source || each.kind == Kind::pointer
                            ? Writer::firmware
                            : Writer::program;
            const int size = each.width == Width::dword ? 2 : 1;
            for (int word = 0; word < size; ++word) {
                Writer &slot =
                        graph.writers_[static_cast<size_t>(each.address + word)];
                slot = slot == Writer::program ? slot : writer;
            }
        }
    }

    // ---- instructions -----------------------------------------------------------

    static Operand at_address(int address) {
        if (address >= sink_base) {
            return {Reach::sink, address - sink_base};
        }
        return address < high_base ? Operand{Reach::direct, address}
                                   : Operand{Reach::high, address - high_base};
    }

    // The offset of a read through a pointer in the record j points at.
    int field_offset(const Node &read) {
        const RecordLayout *record =
                &graph.records_[static_cast<size_t>(graph.target_sets_[
                        static_cast<size_t>(node(read.a).value)].front())];
        if (connected(read.x)) {
            for (const Field &inside : record->fields) {
                if (inside.record.index != none) {
                    record = &graph.records_[static_cast<size_t>(
                            inside.record.index)];
                    break;
                }
            }
        }
        return record->field_offset[static_cast<size_t>(read.value)];
    }

    // A wire as an operand; `group` takes the pointer group of a read through j.
    Operand operand(Wire wire, int32_t &group) {
        if (!connected(wire)) {
            return {Reach::zero, 0};
        }
        const Node &from = node(wire);
        switch (from.kind) {
        case Kind::constant:
            return {Reach::immediate, from.value};
        case Kind::offset:
            return {Reach::immediate,
                    graph.records_[static_cast<size_t>(from.value)].offset};
        case Kind::through:
            if (!from.fetched) {
                group = from.group;
                return {Reach::pointed, field_offset(from)};
            }
            break;
        default:
            break;
        }
        return at_address(from.address);
    }

    int32_t emit(Instruction instruction) {
        const auto at = static_cast<int32_t>(code.size());
        if (instruction.group != none && !instruction.is_idx) {
            groups[static_cast<size_t>(instruction.group)].members.push_back(
                    at);
        }
        code.push_back(std::move(instruction));
        return at;
    }

    // The IDX of a pointer's group, before the group's first member.
    void open_group(int32_t group, const Node &read) {
        Group &opened = groups[static_cast<size_t>(group)];
        if (opened.idx != none) {
            return;
        }
        for (const int32_t target :
             graph.target_sets_[static_cast<size_t>(node(read.a).value)]) {
            const RecordLayout &record =
                    graph.records_[static_cast<size_t>(target)];
            if (!connected(read.x)) {
                opened.may_hold.push_back(record.address);
                continue;
            }
            for (const Field &field : record.fields) {
                if (field.record.index != none) {
                    opened.may_hold.push_back(
                            graph.records_[static_cast<size_t>(
                                                  field.record.index)]
                                    .address);
                }
            }
        }
        Instruction idx;
        idx.op     = Op::idx;
        idx.is_idx = true;
        idx.group  = group;
        int32_t no_group = none;
        idx.x      = operand(read.a, no_group);
        idx.y      = operand(read.x, no_group);
        opened.idx = emit(idx);
    }

    int32_t sinks_group() {
        if (sink_group == none) {
            sink_group = static_cast<int32_t>(groups.size());
            Group sinks;
            sinks.sinks = true;
            groups.push_back(sinks);
        }
        return sink_group;
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
            open_group(row.group, node(through));
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
        const Operand r  = at_address(each.address);
        if (each.kind == Kind::through) {
            if (!each.fetched) {
                return;
            }
            open_group(each.group, each);
            const int offset = field_offset(each);
            copy(r, {Reach::pointed, offset}, each.group);
            if (wide) { // a dword is fetched as its two words
                copy(at_address(each.address + 1),
                     {Reach::pointed, offset + 1}, each.group);
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
                    open_group(row.group, node(each.x));
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
            const int32_t compare =
                    arithmetic(Op::cmp, {Reach::zero, 0}, ASource::zero, each.x,
                               each.y);
            code[static_cast<size_t>(compare)].sets_flags = true;
            const int32_t select =
                    arithmetic(Op::sel, r, ASource::zero, each.a, each.b);
            code[static_cast<size_t>(select)].cond    = each.condition;
            code[static_cast<size_t>(select)].compare = compare;
            break;
        }
        default:
            break;
        }
    }

    void lower_all() {
        // i ← the upper half's base; left out below if nothing is up there
        Instruction high;
        high.op    = Op::idx;
        high.which = IndexRegister::i;
        high.x     = {Reach::immediate, high_base};
        high.y     = {Reach::zero, 0};
        high_idx   = emit(high);
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
            lower(static_cast<int32_t>(at));
        }
        body_end = static_cast<int32_t>(code.size());
        // j ← the sinks; the sinks no operator writes itself are copies
        bool copies = false;
        for (const auto &[address, value] : graph.sinks_) {
            copies = copies || node(value).sink == none;
        }
        if (sink_group != none || copies) {
            Group &sinks = groups[static_cast<size_t>(sinks_group())];
            Instruction idx;
            idx.op     = Op::idx;
            idx.is_idx = true;
            idx.group  = sink_group;
            idx.x      = {Reach::immediate, sink_base};
            idx.y      = {Reach::zero, 0};
            sinks.idx  = emit(idx);
        }
        for (const auto &[address, value] : graph.sinks_) {
            if (node(value).sink != none) {
                continue;
            }
            Instruction row; // sink ← value × 1.0
            row.op         = Op::mac;
            row.r          = at_address(address);
            int32_t group  = none;
            row.x          = operand(value, group);
            row.y          = {Reach::immediate, word_one};
            row.group      = sink_group;
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
        switch (operand.reach) {
        case Reach::direct:
            add(operand.value);
            break;
        case Reach::high:
            add(high_base + operand.value);
            break;
        case Reach::pointed:
            for (const int base :
                 groups[static_cast<size_t>(row.group)].may_hold) {
                add(base | operand.value);
            }
            break;
        default:
            break;
        }
    }

    void find_dependencies() {
        std::map<int, int32_t> last_writer;
        std::map<int, std::vector<int32_t>> readers;
        for (int32_t at = 0; at < static_cast<int32_t>(code.size()); ++at) {
            Instruction &row = code[static_cast<size_t>(at)];
            std::map<int32_t, int> behind;
            auto after = [&](int32_t other, int cycles) {
                if (other != at) {
                    behind[other] = std::max(behind[other], cycles);
                }
            };
            std::vector<int> reads, writes;
            if (row.op != Op::shift) {
                addresses(row, row.x, false, reads);
            }
            if (row.op != Op::abs) {
                addresses(row, row.y, row.wide && row.op != Op::shift, reads);
            }
            if (writes_a_word(row.op)) {
                if (row.a == ASource::result) {
                    addresses(row, row.r, row.wide, reads);
                }
                if (row.r.reach == Reach::direct
                    || row.r.reach == Reach::high) {
                    addresses(row, row.r, row.wide, writes);
                }
            }
            for (const int address : reads) {
                if (last_writer.contains(address)) {
                    after(last_writer[address], result_latency);
                }
            }
            for (const int address : writes) {
                // behind every reader of the word as it was, and its writer
                for (const int32_t reader : readers[address]) {
                    after(reader, 1);
                }
                if (last_writer.contains(address)) {
                    after(last_writer[address], 1);
                }
            }
            for (const int address : reads) {
                readers[address].push_back(at);
            }
            for (const int address : writes) {
                readers[address].clear();
                last_writer[address] = at;
            }
            for (const Operand *operand : {&row.r, &row.x, &row.y}) {
                if (operand->reach == Reach::high) {
                    after(high_idx, index_latency);
                }
            }
            if (row.group != none && !row.is_idx) {
                after(groups[static_cast<size_t>(row.group)].idx,
                      index_latency);
            }
            if (row.compare != none) {
                after(row.compare, state_latency);
            }
            if (row.is_idx && row.group == sink_group) {
                for (int32_t body = 0; body < body_end; ++body) {
                    if (code[static_cast<size_t>(body)].group != sink_group) {
                        after(body, 1);
                    }
                }
            }
            row.behind.assign(behind.begin(), behind.end());
        }
        for (auto at = static_cast<int32_t>(code.size()) - 1; at >= 0; --at) {
            const Instruction &row = code[static_cast<size_t>(at)];
            for (const auto &[other, cycles] : row.behind) {
                Instruction &earlier = code[static_cast<size_t>(other)];
                earlier.height = std::max(earlier.height, row.height + cycles);
            }
        }
    }

    // ---- order ------------------------------------------------------------------------

    // A cycle at a time, the instruction that may issue and matters most:
    // a member of the group that has j, the SEL the flags wait for, an IDX
    // that opens a group whose members can follow at once, a CMP whose SEL
    // can, anything else by its height.
    void schedule() {
        const auto count = static_cast<int32_t>(code.size());
        std::vector<int64_t> issued_at(static_cast<size_t>(count), -1);
        int32_t open_group = none, open_compare = none;
        size_t members_left = 0;
        int64_t cycle       = 0;
        auto can_issue = [&](const Instruction &row, int64_t by,
                             int32_t except) {
            for (const auto &[other, cycles] : row.behind) {
                if (other == except) {
                    continue;
                }
                const int64_t at = issued_at[static_cast<size_t>(other)];
                if (at < 0 || at + cycles > by) {
                    return false;
                }
            }
            return true;
        };
        while (static_cast<int32_t>(order.size()) < count) {
            int32_t best = none, best_rank = 99, best_height = -1;
            for (int32_t at = 0; at < count; ++at) {
                const Instruction &row = code[static_cast<size_t>(at)];
                if (issued_at[static_cast<size_t>(at)] >= 0
                    || !can_issue(row, cycle, none)) {
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
                                    || can_issue(code[static_cast<size_t>(
                                                         member)],
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
            issued_at[static_cast<size_t>(best)] = cycle++;
            order.push_back(best);
            if (row.is_idx && row.group != none) {
                open_group   = row.group;
                members_left = groups[static_cast<size_t>(row.group)]
                                       .members.size();
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

    static csp::Operand machine_operand(const Operand &operand) {
        switch (operand.reach) {
        case Reach::direct:
            return csp::Operand::direct(operand.value);
        case Reach::high:
            return csp::Operand::indexed(IndexRegister::i, operand.value);
        case Reach::pointed:
        case Reach::sink:
            return csp::Operand::indexed(IndexRegister::j, operand.value);
        case Reach::zero:
            return csp::Operand::direct(0);
        default:
            return csp::Operand::none();
        }
    }

    static Source machine_source(const Operand &operand) {
        return operand.reach == Reach::immediate
                       ? Source::imm(operand.value)
                       : Source::reg(machine_operand(operand));
    }

    void emit_program(ProgramBuilder::Built &built) {
        ProgramBuilder program;
        std::map<std::vector<int>, IndexTargets> lists;
        for (const int32_t at : order) {
            const Instruction &row = code[static_cast<size_t>(at)];
            const csp::Operand r   = machine_operand(row.r);
            const Source x = machine_source(row.x), y = machine_source(row.y);
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
                                ? &groups[static_cast<size_t>(row.group)]
                                           .may_hold
                                : nullptr;
                if (may_hold && !may_hold->empty()) {
                    if (!lists.contains(*may_hold)) {
                        lists[*may_hold] = program.targets(*may_hold);
                    }
                    program.idx(row.which, x, y, lists[*may_hold]);
                } else {
                    program.idx(row.which, x, y);
                }
                break;
            }
            default:
                break;
            }
        }
        program.build(built);
        for (const BuildIssue &found : built.issues) {
            if (found.error) {
                graph.issue(found.message);
            }
        }
    }

    bool run(ProgramBuilder::Built &built) {
        find_groups_and_fetches();
        decide_storage();
        lay_out();
        if (!graph.issues_.empty()) {
            return false;
        }
        lower_all();
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
    Lowering lowering(*this);
    return lowering.run(built);
}

} // namespace csp
