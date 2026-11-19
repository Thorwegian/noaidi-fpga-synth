// dsp_graph_test.cpp — host tests for the DSP graph (app/main/csp/dsp_graph.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Three things. Each operator and each kind of connection in a small graph,
// its image run on the reference model beside the graph's interpreter
// (graph_evaluator.hpp), every value checked as it was worked out by hand and
// every sink equal in both. And the Noaidi's wiring (app/main/wiring.cpp: 8
// LFOs, 16 channels, 32 voices, the copies made by loops), its image run on
// the reference model beside the interpreter on the same performance
// (tools/csp/performance.hpp) of notes and controller values, wires moved
// while it plays: every sink the graph has holds the same value, pass for
// pass, and the model reports no read before ready. The test prints the
// image's rows and the pass's cycles. And that wiring by the Noaidi's
// formulas in floating point: every sink with the LFOs standing at phases of
// their own, and an envelope from a note on to its release, pass for pass.
//
//   make csp-test

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "../performance.hpp"
#include "../processor.hpp"
#include "csp/dsp_graph.hpp"
#include "graph_evaluator.hpp"
#include "wiring.hpp"

namespace {

using Graph    = csp::DspGraph;
using Wire     = Graph::Wire;
using Record   = Graph::Record;
using Field    = Graph::Field;
using Width    = Graph::Width;
using Overflow = Graph::Overflow;

int failures = 0;
int checks   = 0;

void check(bool ok, const std::string &what) {
    ++checks;
    if (!ok) {
        std::printf("FAIL %s\n", what.c_str());
        ++failures;
    }
}

void check_equal(int64_t got, int64_t want, const std::string &what) {
    ++checks;
    if (got != want) {
        std::printf("FAIL %s: got %lld, want %lld\n", what.c_str(),
                    static_cast<long long>(got), static_cast<long long>(want));
        ++failures;
    }
}

int32_t q(double value) {
    return static_cast<int32_t>(std::llround(value * csp::word_one));
}

int64_t q_wide(double value) {
    return std::llround(
            value * static_cast<double>(int64_t{1} << csp::wide_fraction_bits));
}

bool build(Graph &graph, csp::ProgramBuilder::Built &built,
           const std::string &what) {
    const bool ok = graph.build(built);
    for (const Graph::Issue &issue : graph.issues()) {
        std::printf("  %s: %s\n", what.c_str(), issue.message.c_str());
    }
    check(ok, what + " builds");
    return ok;
}

// The firmware's writes so far applied, the image loaded, the CSP let go.
void start(csp::Processor &processor, const csp::Image &image) {
    processor.swap();
    while (processor.queued_writes() > 0) {
        processor.pass();
    }
    check(processor.load(image), "the image loads");
    processor.release();
}

// A pass, with the model's own complaints counted as failures.
void pass(csp::Processor &processor, const std::string &what) {
    const csp::PassReport report = processor.pass();
    for (const std::string &error : report.errors) {
        check(false, what + ": " + error);
    }
}

// Every sink the graph has, the interpreter's against the model's.
void compare_sinks(const csp::GraphEvaluator &evaluator,
                   const csp::Processor &processor, const std::string &what) {
    for (const int address : evaluator.sink_addresses()) {
        check_equal(evaluator.sink(address),
                    processor.sink(address - csp::sink_base),
                    what + ": sink " + std::to_string(address));
    }
}

// ---- every operator and connection -----------------------------------------------

void test_operators() {
    Graph graph;
    const Wire a = graph.source(), b = graph.source(), c = graph.source();
    const Wire large = graph.source(), larger = graph.source();
    int sinks = 0;
    auto sink = [&](Wire value) {
        graph.sink(csp::sink_base + sinks, value);
        return sinks++;
    };
    const int sum_of_two   = sink(graph.sum(a, b));
    const int sum_of_three = sink(graph.sum(a, b, c));
    const int product      = sink(graph.multiply(a, b));
    const int product_sum  = sink(graph.multiply_add(c, a, b));
    const int difference   = sink(graph.difference(a, b));
    const int absolute     = sink(graph.absolute(graph.difference(b, c)));
    const int maximum      = sink(graph.maximum(a, b));
    const int minimum      = sink(graph.minimum(a, b));
    const int shifted      = sink(graph.shift(a, 2));
    const int shifted_down = sink(graph.shift(c, -3));
    const int larger_of =
            sink(graph.select(a, b, csp::Condition::negative, a, b));
    const int saturated = sink(graph.sum(large, larger));
    const int wrapped   = sink(graph.sum(large, larger, {}, Overflow::wrap));
    const int constant  = sink(graph.sum(a, graph.constant(q(1.5))));

    // a counter: a sum onto its own delayed output, and what it was. The
    // sum has the longer way to the pass's end, so the order has to hold it
    // back for the reader of the word as it was.
    const Wire count    = graph.delay();
    const int was       = sink(graph.sum({}, count, {}));
    const Wire counting = graph.sum(count, graph.constant(q(0.25)));
    graph.connect(count, counting);
    const int counted = sink(
            graph.multiply(graph.multiply(counting, graph.constant(q(2.0))),
                           graph.constant(q(0.5))));

    // a dword onto its own delayed output: steps of a × step
    const Wire step      = graph.source(Width::dword);
    const Wire total     = graph.delay(Width::dword);
    const Wire totalling = graph.multiply_add(total, a, step);
    graph.connect(total, totalling);
    const int totalled =
            sink(graph.multiply(totalling, graph.constant(q(1.0))));

    // a movable wire: a field of whichever record the pointer holds, and the
    // same in a record inside it
    struct Target {
        Wire gain, low, high;
        Record lows, highs, record;
    } targets[3];
    std::vector<Record> records;
    for (Target &target : targets) {
        target.gain = graph.source();
        target.low  = graph.source();
        target.high = graph.source();
        const std::vector<Field> lows{target.low};
        const std::vector<Field> highs{target.high};
        target.lows  = graph.record(lows);
        target.highs = graph.record(highs);
        const std::vector<Field> fields{target.gain, target.lows, target.highs};
        target.record = graph.record(fields);
        records.push_back(target.record);
    }
    const Wire pointer = graph.pointer(records);
    const Wire which   = graph.source(); // an offset the firmware writes
    const int pointed  = sink(graph.multiply(a, graph.through(pointer, 0)));
    const int inside   = sink(graph.sum(a, graph.through(pointer, which, 0)));
    const int straight = sink(graph.through(pointer, 0));

    csp::ProgramBuilder::Built built;
    if (!build(graph, built, "the small graph")) {
        return;
    }
    check(graph.address(a) >= csp::io_base + csp::io_count
                  && graph.address(a) < csp::direct_reach,
          "a fixed wire's word is one a direct operand reaches");
    check(graph.address(targets[1].record) >= csp::direct_reach,
          "a record lies in the upper half");
    check_equal(graph.address(targets[2].gain),
                graph.address(targets[2].record),
                "a record's first field is at its address");
    check(graph.offset(targets[0].highs) > graph.offset(targets[0].lows),
          "records inside a record lie in the order given");
    check(graph.address(step) % 2 == 0, "a dword is an aligned pair");
    check(graph.writer(graph.address(a)) == Graph::Writer::firmware,
          "a source is the firmware's word");
    check(graph.writer(graph.address(step) + 1) == Graph::Writer::firmware,
          "both words of a dword source are");
    check(graph.writer(graph.address(pointer)) == Graph::Writer::firmware,
          "a pointer is the firmware's word");
    check(graph.writer(graph.address(counting)) == Graph::Writer::program,
          "an operator's output is the program's word");
    check_equal(graph.address(count), graph.address(counting),
                "a delay is its input's word");
    check(graph.writer(0x3F) == Graph::Writer::nobody,
          "a word the graph did not lay out is nobody's");

    csp::Processor processor;
    csp::GraphEvaluator evaluator(graph);
    auto set_word = [&](Wire wire, int32_t raw) {
        processor.write(graph.address(wire), raw);
        evaluator.set_word(wire, raw);
    };
    auto set_dword = [&](Wire wire, int64_t raw) {
        processor.write_wide(graph.address(wire), raw);
        evaluator.set_dword(wire, raw);
    };
    auto set_pointer = [&](Wire wire, Record record) {
        processor.write(graph.address(wire), graph.address(record));
        evaluator.set_pointer(wire, record);
    };
    auto set_offset = [&](Wire wire, Record inner) {
        processor.write(graph.address(wire), graph.offset(inner));
        evaluator.set_offset(wire, inner);
    };
    set_word(a, q(0.5));
    set_word(b, q(0.25));
    set_word(c, q(2.0));
    set_word(large, q(6.0));
    set_word(larger, q(5.0));
    set_dword(step, q_wide(0.75));
    for (int t = 0; t < 3; ++t) {
        set_word(targets[t].gain, q(0.5 * (t + 1)));
        set_word(targets[t].low, q(-1.0 - t));
        set_word(targets[t].high, q(1.0 + t));
    }
    set_pointer(pointer, targets[0].record);
    set_offset(which, targets[0].lows);
    start(processor, built.image);

    pass(processor, "the small graph");
    evaluator.pass();
    check_equal(processor.sink(sum_of_two), q(0.75), "a sum of two");
    check_equal(processor.sink(sum_of_three), q(2.75), "a sum of three");
    check_equal(processor.sink(product), q(0.125), "a product");
    check_equal(processor.sink(product_sum), q(2.125), "a multiply-add");
    check_equal(processor.sink(difference), q(0.25), "a difference");
    check_equal(processor.sink(absolute), q(1.75), "an absolute value");
    check_equal(processor.sink(maximum), q(0.5), "a maximum");
    check_equal(processor.sink(minimum), q(0.25), "a minimum");
    check_equal(processor.sink(shifted), q(2.0), "a shift up");
    check_equal(processor.sink(shifted_down), q(0.25), "a shift down");
    check_equal(processor.sink(larger_of), q(0.5),
                "a select: x − y is not negative, so the first");
    check_equal(processor.sink(saturated), csp::largest(csp::word_bits),
                "a sum saturates");
    check_equal(processor.sink(wrapped), q(-5.0), "a wrapping sum wraps");
    check_equal(processor.sink(constant), q(2.0), "a sum with a constant");
    check_equal(processor.sink(was), 0, "a delay's output in the first pass");
    check_equal(processor.sink(counted), q(0.25), "and its input's");
    check_equal(processor.sink(pointed), q(0.25),
                "a field through the pointer");
    check_equal(processor.sink(inside), q(-0.5),
                "a field of a record inside it");
    check_equal(processor.sink(straight), q(0.5),
                "a field through the pointer straight to a sink");
    compare_sinks(evaluator, processor, "the small graph");

    pass(processor, "the small graph");
    evaluator.pass();
    pass(processor, "the small graph");
    evaluator.pass();
    check_equal(processor.sink(was), q(0.5),
                "a delay's output is its input's value of the pass before");
    check_equal(processor.sink(counted), q(0.75),
                "a sum onto its own delayed output counts");
    check_equal(processor.read_wide(graph.address(totalling)), q_wide(1.125),
                "a dword multiply-add onto its own delayed output");
    check_equal(processor.sink(totalled), q(1.125),
                "an operator of words reads a dword's upper word");
    check_equal(evaluator.probe(totalling), q_wide(1.125),
                "the interpreter's dword accumulation is the model's, whole");
    compare_sinks(evaluator, processor, "the small graph");

    // the wire moved: one write of the pointer, one of the offset
    processor.write(graph.address(pointer), graph.address(targets[2].record));
    processor.write(graph.address(which), graph.offset(targets[2].highs));
    processor.swap();
    pass(processor, "the small graph");
    evaluator.pass();
    compare_sinks(evaluator, processor, "the small graph");
    // the writes land in the model at the end of the pass they are swapped
    // before: the interpreter takes them for the pass after
    evaluator.set_pointer(pointer, targets[2].record);
    evaluator.set_offset(which, targets[2].highs);
    pass(processor, "the small graph");
    evaluator.pass();
    check_equal(processor.sink(pointed), q(0.75),
                "the pointer moved, the field follows");
    check_equal(processor.sink(inside), q(3.5),
                "the offset moved, the record inside follows");
    check_equal(processor.sink(straight), q(1.5), "and the sink's");
    compare_sinks(evaluator, processor, "the small graph");
}

// What the graph refuses.
void test_refusals() {
    auto refused = [](Graph &graph, const std::string &what) {
        csp::ProgramBuilder::Built built;
        check(!graph.build(built) && !graph.issues().empty(),
              what + " is refused");
    };
    {
        Graph graph;
        const Wire held = graph.delay();
        graph.sink(csp::sink_base, graph.sum(held, graph.constant(q(1.0))));
        refused(graph, "a delay without an input");
    }
    {
        Graph graph;
        const Wire held = graph.delay();
        const Wire next = graph.sum(held, graph.constant(q(1.0)));
        graph.connect(held, next);
        graph.sink(csp::sink_base, graph.multiply(held, next));
        refused(graph, "a delay read by a node made after its input");
    }
    {
        Graph graph;
        const Wire value = graph.source();
        const Wire held  = graph.delay();
        graph.connect(held, value);
        graph.sink(csp::sink_base, graph.sum({}, held, value));
        refused(graph, "a delay of a source");
    }
    {
        Graph graph;
        const Wire wide = graph.source(Width::dword);
        graph.sink(csp::sink_base,
                   graph.multiply_add(wide, graph.source(), wide));
        refused(graph, "a dword operator that is not in place");
    }
    {
        Graph graph;
        graph.sink(csp::sink_base,
                   graph.sum({}, graph.constant(1), graph.constant(2)));
        refused(graph, "an operator with two constants");
    }
    {
        Graph graph;
        for (int word = 0; word < csp::register_count; ++word) {
            graph.source();
        }
        refused(graph, "a graph of more words than DMEM has");
    }
}

// A record's field with one reader by a fixed wire, a sum that works on its
// operand in place: the field keeps its word, since what reads it through a
// pointer is to get the field and not the sum.
void test_a_field_summed_onto() {
    Graph graph;
    const Wire a = graph.source(), b = graph.source();
    const Wire field = graph.sum({}, a, b);
    const std::vector<Field> fields{field};
    const Record record = graph.record(fields);
    graph.sink(csp::sink_base, graph.sum(field, a));
    const std::vector<Record> records{record};
    const Wire pointer = graph.pointer(records);
    graph.sink(csp::sink_base + 1, graph.multiply(graph.through(pointer, 0),
                                                  graph.constant(q(1.0))));
    csp::ProgramBuilder::Built built;
    if (!build(graph, built, "the field summed onto")) {
        return;
    }
    csp::Processor processor;
    processor.write(graph.address(a), q(0.5));
    processor.write(graph.address(b), q(0.25));
    processor.write(graph.address(pointer), graph.address(record));
    csp::GraphEvaluator evaluator(graph);
    evaluator.set_word(a, q(0.5));
    evaluator.set_word(b, q(0.25));
    evaluator.set_pointer(pointer, record);
    start(processor, built.image);
    pass(processor, "the field summed onto");
    evaluator.pass();
    check_equal(processor.sink(0), q(1.25), "a sum onto a record's field");
    check_equal(processor.sink(1), q(0.75),
                "the field through a pointer, a sum onto it made");
    compare_sinks(evaluator, processor, "the field summed onto");
}

// ---- copies and loops -------------------------------------------------------------
//
// A small circuit made `count` times over by an ordinary loop, as the top
// makes its voices: two selects that take the flags in turn, one of them
// reading through a pointer; a chain of products through one pointer,
// through another, and through the first again; a field with three readers;
// a word that all the copies share; a counter. Built at counts the graph
// loops over and at counts it does not, every sink has the value worked out
// here, before and after the wires are moved.

constexpr int copy_sinks = 8; // a copy's block of sinks
enum {
    sink_larger,
    sink_smaller,
    sink_chain,
    sink_twice,
    sink_shared,
    sink_counter
};

void test_copies(int count, bool looped, int body_rows) {
    const std::string what = std::to_string(count) + " copies";
    const double gains[3] = {0.5, 1.0, 1.5}, levels[3] = {0.25, 0.5, 1.0};
    const double scales[2] = {0.5, 2.0};
    const double shared    = 0.5;
    auto a_of              = [](int c) {
        return 0.125 * (1 + c % 5);
    };
    auto b_of = [](int c) {
        return 0.25 * (1 + c * 3 % 7);
    };

    Graph graph;
    struct Target {
        Wire gain, level;
        Record record;
    } targets[3];
    std::vector<Record> target_records;
    for (Target &target : targets) {
        target.gain  = graph.source();
        target.level = graph.source();
        const std::vector<Field> fields{target.gain, target.level};
        target.record = graph.record(fields);
        target_records.push_back(target.record);
    }
    struct Scale {
        Wire scale;
        Record record;
    } scalers[2];
    std::vector<Record> scale_records;
    for (Scale &scaler : scalers) {
        scaler.scale = graph.source();
        const std::vector<Field> fields{scaler.scale};
        scaler.record = graph.record(fields);
        scale_records.push_back(scaler.record);
    }
    const Wire master = graph.source();
    struct Copy {
        Wire a, b, target, scaler;
    };
    std::vector<Copy> copies(static_cast<size_t>(count));
    for (int c = 0; c < count; ++c) {
        Copy &copy       = copies[static_cast<size_t>(c)];
        copy.a           = graph.source();
        copy.b           = graph.source();
        copy.target      = graph.pointer(target_records);
        copy.scaler      = graph.pointer(scale_records);
        const Wire gain  = graph.through(copy.target, 0);
        const Wire level = graph.through(copy.target, 1);
        const Wire scale = graph.through(copy.scaler, 0);
        const int sinks  = csp::sink_base + copy_sinks * c;
        // b where a is the smaller, else the gain behind the pointer
        graph.sink(sinks + sink_larger,
                   graph.select(copy.a, copy.b, csp::Condition::negative, gain,
                                copy.b));
        graph.sink(sinks + sink_smaller,
                   graph.select(copy.b, copy.a, csp::Condition::negative,
                                copy.a, copy.b));
        graph.sink(sinks + sink_chain,
                   graph.multiply(
                           graph.multiply(graph.multiply(copy.a, gain), scale),
                           level));
        graph.sink(sinks + sink_twice,
                   graph.sum({}, graph.multiply(copy.a, level),
                             graph.multiply(copy.b, level)));
        graph.sink(sinks + sink_shared, graph.multiply(copy.b, master));
        const Wire counted  = graph.delay();
        const Wire counting = graph.sum(counted, copy.a);
        graph.connect(counted, counting);
        graph.sink(sinks + sink_counter, counting);
    }

    csp::ProgramBuilder::Built built;
    if (!build(graph, built, what)) {
        return;
    }
    bool found = false;
    for (const Graph::CopySet &set : graph.copy_sets()) {
        if (set.copies != count) {
            continue;
        }
        found = true;
        check(set.looped == looped,
              what
                      + (looped ? " are a vector loop"
                                : " are straight-line code"));
        if (looped) {
            check_equal(set.rows, body_rows,
                        what + ": the instruction rows of the loop body");
        }
    }
    check(found, what + " are found");
    check_equal(static_cast<int64_t>(graph.initial_values().size()),
                looped ? count : 0,
                what + ": pointers to sinks for the firmware to set");

    auto processor = std::make_unique<csp::Processor>();
    csp::GraphEvaluator evaluator(graph);
    auto word = [&](Wire wire, int32_t raw) {
        processor->write(graph.address(wire), raw);
        evaluator.set_word(wire, raw);
    };
    auto point_model = [&](int moved) {
        for (int c = 0; c < count; ++c) {
            const Copy &copy = copies[static_cast<size_t>(c)];
            processor->write(graph.address(copy.target),
                             graph.address(targets[(c + moved) % 3].record));
            processor->write(graph.address(copy.scaler),
                             graph.address(scalers[(c + moved) % 2].record));
        }
    };
    auto point_graph = [&](int moved) {
        for (int c = 0; c < count; ++c) {
            const Copy &copy = copies[static_cast<size_t>(c)];
            evaluator.set_pointer(copy.target, targets[(c + moved) % 3].record);
            evaluator.set_pointer(copy.scaler, scalers[(c + moved) % 2].record);
        }
    };
    for (int t = 0; t < 3; ++t) {
        word(targets[t].gain, q(gains[t]));
        word(targets[t].level, q(levels[t]));
    }
    for (int s = 0; s < 2; ++s) {
        word(scalers[s].scale, q(scales[s]));
    }
    word(master, q(shared));
    for (int c = 0; c < count; ++c) {
        word(copies[static_cast<size_t>(c)].a, q(a_of(c)));
        word(copies[static_cast<size_t>(c)].b, q(b_of(c)));
    }
    for (const Graph::InitialValue &initial : graph.initial_values()) {
        processor->write(initial.address, initial.value);
    }
    point_model(0);
    point_graph(0);
    start(*processor, built.image);

    int passes  = 0;
    auto expect = [&](int moved) {
        int wrong = 0;
        for (int c = 0; c < count; ++c) {
            const double a = a_of(c), b = b_of(c);
            const double gain   = gains[(c + moved) % 3];
            const double level  = levels[(c + moved) % 3];
            const double scale  = scales[(c + moved) % 2];
            const double want[] = {a - b < 0 ? b : gain,
                                   b - a < 0 ? b : a,
                                   a * gain * scale * level,
                                   a * level + b * level,
                                   b * shared,
                                   passes * a};
            for (int k = 0; k <= sink_counter; ++k) {
                const int32_t got = processor->sink(copy_sinks * c + k);
                if (got != q(want[k]) && wrong++ < 3) {
                    std::printf("  %s, copy %d sink %d: %d, want %d\n",
                                what.c_str(), c, k, got, q(want[k]));
                }
            }
        }
        return wrong;
    };
    for (; passes < 2; ++passes) {
        pass(*processor, what);
        evaluator.pass();
    }
    check_equal(expect(0), 0, what + ": sinks that are wrong");
    compare_sinks(evaluator, *processor, what);
    point_model(1); // every wire moved
    processor->swap();
    // the writes land a share a pass, the first at the end of this one: the
    // interpreter takes them all for the pass after
    pass(*processor, what);
    evaluator.pass();
    ++passes;
    compare_sinks(evaluator, *processor, what);
    point_graph(1);
    while (processor->queued_writes() > 0) {
        pass(*processor, what);
        evaluator.pass();
        ++passes;
    }
    for (int settled = 0; settled < 2; ++settled, ++passes) {
        pass(*processor, what);
        evaluator.pass();
    }
    check_equal(expect(1), 0, what + ": sinks that are wrong, the wires moved");
    compare_sinks(evaluator, *processor, what);
}

// Two like parts in one circuit, each a running total of its own gain. The
// graph tells copies by their wiring; which of two like nodes is which it
// takes from the order they were made in, and compares the circuits node by
// node on that. One copy here makes its two parts in the other order: it is
// no copy to the graph, stays straight-line code beside the loop over the
// rest, and every total is right.
void test_a_copy_made_otherwise() {
    constexpr int count = 10, otherwise = 4, parts = 2;
    const double gains[parts] = {0.5, 1.5};
    auto a_of                 = [](int c) {
        return 0.25 * (1 + c % 3);
    };
    Graph graph;
    struct Twin {
        Wire a, gain[parts], total[parts];
    } twins[count];
    for (int c = 0; c < count; ++c) {
        Twin &twin = twins[c];
        twin.a     = graph.source();
        for (Wire &gain : twin.gain) {
            gain = graph.source();
        }
        for (int made = 0; made < parts; ++made) {
            const int part  = c == otherwise ? parts - 1 - made : made;
            const Wire held = graph.delay();
            twin.total[part] =
                    graph.multiply_add(held, twin.a, twin.gain[part]);
            graph.connect(held, twin.total[part]);
        }
    }
    csp::ProgramBuilder::Built built;
    if (!build(graph, built, "the copy made otherwise")) {
        return;
    }
    check(graph.copy_sets().size() == 1
                  && graph.copy_sets().front().copies == count - 1
                  && graph.copy_sets().front().looped,
          "the copies made alike are a vector loop, without the one made otherwise");

    auto processor = std::make_unique<csp::Processor>();
    for (int c = 0; c < count; ++c) {
        processor->write(graph.address(twins[c].a), q(a_of(c)));
        for (int part = 0; part < parts; ++part) {
            processor->write(graph.address(twins[c].gain[part]),
                             q(gains[part]));
        }
    }
    start(*processor, built.image);
    constexpr int passes = 3;
    for (int at = 0; at < passes; ++at) {
        pass(*processor, "the copy made otherwise");
    }
    int wrong = 0;
    for (int c = 0; c < count; ++c) {
        for (int part = 0; part < parts; ++part) {
            wrong += processor->read(graph.address(twins[c].total[part]))
                                     != q(passes * a_of(c) * gains[part])
                             ? 1
                             : 0;
        }
    }
    check_equal(
            wrong, 0,
            "totals that are wrong, of the loop's copies and the one made otherwise");
}

// Copies whose pointers point at each other: every copy counts, and adds
// to its own input what the counter of the copy it points at was a pass
// ago. An element of a vector loop reads no word that another element
// writes, so these are no loop, however many they are.
void test_copies_that_point_at_each_other() {
    constexpr int count = 12, sinks_from = 512;
    auto a_of = [](int c) {
        return 0.125 * (1 + c % 4);
    };
    Graph graph;
    struct Counter {
        Wire a, held, other;
        Record record;
    } counters[count];
    std::vector<Record> records;
    for (Counter &counter : counters) {
        counter.a    = graph.source();
        counter.held = graph.delay();
        const std::vector<Field> fields{counter.held};
        counter.record = graph.record(fields);
        records.push_back(counter.record);
    }
    // the readers of every counter as it was, then the counters' renewal
    for (int c = 0; c < count; ++c) {
        counters[c].other = graph.pointer(records);
        graph.sink(
                csp::sink_base + sinks_from + c,
                graph.sum(counters[c].a, graph.through(counters[c].other, 0)));
    }
    for (Counter &counter : counters) {
        graph.connect(counter.held, graph.sum(counter.held, counter.a));
    }
    csp::ProgramBuilder::Built built;
    if (!build(graph, built, "copies that point at each other")) {
        return;
    }
    check(graph.copy_sets().size() == 1
                  && graph.copy_sets().front().copies == count
                  && !graph.copy_sets().front().looped,
          "copies that point at each other are found, and are straight-line code");
    auto processor = std::make_unique<csp::Processor>();
    csp::GraphEvaluator evaluator(graph);
    for (int c = 0; c < count; ++c) {
        processor->write(graph.address(counters[c].a), q(a_of(c)));
        processor->write(graph.address(counters[c].other),
                         graph.address(counters[(c + 5) % count].record));
        evaluator.set_word(counters[c].a, q(a_of(c)));
        evaluator.set_pointer(counters[c].other,
                              counters[(c + 5) % count].record);
    }
    start(*processor, built.image);
    constexpr int passes = 3;
    for (int at = 0; at < passes; ++at) {
        pass(*processor, "copies that point at each other");
        evaluator.pass();
        compare_sinks(evaluator, *processor, "copies that point at each other");
    }
    int wrong = 0;
    for (int c = 0; c < count; ++c) {
        wrong += processor->sink(sinks_from + c)
                                 != q(a_of(c)
                                      + (passes - 1) * a_of((c + 5) % count))
                         ? 1
                         : 0;
    }
    check_equal(wrong, 0,
                "sums that are wrong, of copies that point at each other");
}

// ---- the interpreter's arithmetic --------------------------------------------------
//
// The corners the Noaidi's graph does not reach, on the model and on the
// interpreter both: a dword sum and a dword multiply-add onto their own
// delayed outputs (they take x as a word, 18 bits below the sum), a wrapping
// dword accumulation, a shift and a sum that run out of range in both
// directions, the absolute value of the most negative word, a compare whose
// difference saturates and the select that reads its overflow flag, and a
// pointer and an offset moved while it runs.

void test_the_interpreter() {
    Graph graph;
    const Wire word  = graph.source();             // a word, 0.25
    const Wire big   = graph.source();             // a word, 6.0
    const Wire step  = graph.source(Width::dword); // a dword step, 0.75
    const Wire least = graph.constant(csp::smallest(csp::word_bits));
    const Wire one   = graph.constant(q(1.0));
    int sinks        = 0;
    auto sink        = [&](Wire value) {
        graph.sink(csp::sink_base + sinks, value);
        return sinks++;
    };
    // onto its own delayed output, a dword sum adds the word 18 bits up
    const Wire level     = graph.delay(Width::dword);
    const Wire levelling = graph.sum(level, word);
    graph.connect(level, levelling);
    const int level_word = sink(graph.multiply(levelling, one));
    // and a wrapping dword multiply-add runs past 8.0 and comes back
    const Wire phase   = graph.delay(Width::dword);
    const Wire phasing = graph.multiply_add(phase, one, step, Overflow::wrap);
    graph.connect(phase, phasing);
    const int phase_word = sink(graph.multiply(phasing, one));

    const int shifted_out    = sink(graph.shift(big, 4));
    const int absolute_least = sink(graph.absolute(least));
    const int saturated_add  = sink(graph.sum(big, big));
    const int wrapped_add    = sink(graph.sum(big, big, {}, Overflow::wrap));
    // 6.0 − (−8.0) is 14.0: the CMP saturates it and flags the overflow
    const int overflowed =
            sink(graph.select(big, least, csp::Condition::overflow, word, big));
    // 0.25 − 6.0 is in range and flags nothing
    const int not_overflowed =
            sink(graph.select(word, big, csp::Condition::overflow, word, big));
    // −8.0 − 6.0 saturates to the most negative word: negative holds
    const int saturated_difference =
            sink(graph.select(least, big, csp::Condition::negative, word, big));

    // a movable wire, and a record inside it
    struct Target {
        Wire gain, low, high;
        Record lows, highs, record;
    } targets[2];
    std::vector<Record> records;
    for (Target &target : targets) {
        target.gain = graph.source();
        target.low  = graph.source();
        target.high = graph.source();
        const std::vector<Field> lows{target.low};
        const std::vector<Field> highs{target.high};
        target.lows  = graph.record(lows);
        target.highs = graph.record(highs);
        const std::vector<Field> fields{target.gain, target.lows, target.highs};
        target.record = graph.record(fields);
        records.push_back(target.record);
    }
    const Wire pointer = graph.pointer(records);
    const Wire which   = graph.source();
    const int straight = sink(graph.through(pointer, 0));
    const int inside   = sink(graph.through(pointer, which, 0));

    csp::ProgramBuilder::Built built;
    if (!build(graph, built, "the interpreter's corners")) {
        return;
    }
    csp::Processor processor;
    csp::GraphEvaluator evaluator(graph);
    auto set_word = [&](Wire wire, int32_t raw) {
        processor.write(graph.address(wire), raw);
        evaluator.set_word(wire, raw);
    };
    set_word(word, q(0.25));
    set_word(big, q(6.0));
    processor.write_wide(graph.address(step), q_wide(0.75));
    evaluator.set_dword(step, q_wide(0.75));
    const double gains[2] = {0.5, -1.5}, lows[2] = {-1.0, 2.0},
                 highs[2] = {1.0, -2.0};
    for (int t = 0; t < 2; ++t) {
        set_word(targets[t].gain, q(gains[t]));
        set_word(targets[t].low, q(lows[t]));
        set_word(targets[t].high, q(highs[t]));
    }
    processor.write(graph.address(pointer), graph.address(targets[0].record));
    processor.write(graph.address(which), graph.offset(targets[0].lows));
    for (const Graph::InitialValue &initial : graph.initial_values()) {
        processor.write(initial.address, initial.value);
    }
    evaluator.set_pointer(pointer, targets[0].record);
    evaluator.set_offset(which, targets[0].lows);
    start(processor, built.image);

    constexpr int moves_after = 6, passes = 12;
    for (int at = 1; at <= passes; ++at) {
        if (at == moves_after + 1) {
            // the wire and the offset move: the model takes the writes at
            // the end of this pass, the interpreter for the pass after
            processor.write(graph.address(pointer),
                            graph.address(targets[1].record));
            processor.write(graph.address(which),
                            graph.offset(targets[1].highs));
            processor.swap();
        }
        pass(processor, "the interpreter's corners");
        evaluator.pass();
        if (at == moves_after + 1) {
            evaluator.set_pointer(pointer, targets[1].record);
            evaluator.set_offset(which, targets[1].highs);
        }
        compare_sinks(evaluator, processor, "the interpreter's corners");
    }

    // the same arithmetic worked out here
    check_equal(processor.sink(level_word), q(3.0),
                "a dword sum adds the word 18 bits up");
    check_equal(processor.sink(phase_word), q(-7.0),
                "a wrapping dword multiply-add wraps past 8.0");
    check_equal(evaluator.probe(levelling), q_wide(3.0),
                "the interpreter's dword sum, whole");
    check_equal(evaluator.probe(phasing), q_wide(-7.0),
                "the interpreter's wrapping dword multiply-add, whole");
    check_equal(processor.sink(shifted_out), csp::largest(csp::word_bits),
                "a shift out of range saturates");
    check_equal(processor.sink(absolute_least), csp::largest(csp::word_bits),
                "the least word's absolute value saturates");
    check_equal(processor.sink(saturated_add), csp::largest(csp::word_bits),
                "a saturating sum saturates");
    check_equal(processor.sink(wrapped_add), q(-4.0), "a wrapping sum wraps");
    check_equal(processor.sink(overflowed), q(6.0),
                "a compare that overflows takes the set value");
    check_equal(processor.sink(not_overflowed), q(0.25),
                "a compare that does not takes the clear value");
    check_equal(processor.sink(saturated_difference), q(6.0),
                "a difference that saturates negative is negative");
    check_equal(processor.sink(straight), q(-1.5),
                "the pointer moved, the field follows");
    check_equal(processor.sink(inside), q(-2.0),
                "the offset moved, the record inside follows");
}

// ---- the Noaidi's wiring -------------------------------------------------------------
//
// The synth the firmware wires (app/main/wiring.cpp) and the performance it
// plays (tools/csp/performance.hpp): the settings on a processor, which runs
// the graph's program, and on the interpreter, which reads the graph itself.
// Every sink the graph has is checked, pass for pass.

using wiring::channel_count;
using wiring::voice_count;

using Synth = wiring::Synth;

// A setting on the interpreter: the number, the record or the inner record
// the firmware's write carries.
void set(csp::GraphEvaluator &evaluator, const performance::Setting &setting) {
    switch (setting.kind) {
    case performance::Setting::Kind::word:
        evaluator.set_word(setting.wire, static_cast<int32_t>(setting.raw));
        break;
    case performance::Setting::Kind::dword:
        evaluator.set_dword(setting.wire, setting.raw);
        break;
    case performance::Setting::Kind::pointer:
        evaluator.set_pointer(setting.wire, setting.record);
        break;
    case performance::Setting::Kind::offset:
        evaluator.set_offset(setting.wire, setting.record);
        break;
    }
}

void test_todays_synth() {
    auto synth   = std::make_unique<Synth>();
    Graph &graph = synth->graph;
    wiring::wire(*synth);
    csp::ProgramBuilder::Built graphed;
    const auto began = std::chrono::steady_clock::now();
    const bool built = build(graph, graphed, "today's synth as a graph");
    const auto took  = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - began);
    if (!built) {
        return;
    }
    int direct = 0, upper = 0;
    for (int address = 0; address < csp::register_count; ++address) {
        if (graph.writer(address) != Graph::Writer::nobody) {
            ++(address < csp::direct_reach ? direct : upper);
        }
    }
    std::printf(
            "today's synth from the graph (the loops it finds): %d rows, %d decode rows, %d cycles a pass; %zu instructions, %d rows of waiting\n",
            graphed.image.length, graphed.image.rom_used, graphed.cycles,
            graphed.position.size(),
            graphed.image.length - static_cast<int>(graphed.position.size()));
    std::printf(
            "the graph's words: %d in the direct half, %d in the upper half; built in %lld ms on this host\n",
            direct, upper, static_cast<long long>(took.count()));
    check(graphed.image.length <= csp::program_limit,
          "the graph's program fits IMEM");
    check(graphed.cycles <= csp::pass_cycle_limit,
          "the graph's program fits the pass");

    check(graph.writer(graph.address(synth->voices[5].note))
                  == Graph::Writer::firmware,
          "a voice's note is the firmware's word");
    check(graph.writer(graph.address(synth->voices[5].stage[1]))
                  == Graph::Writer::program,
          "a voice's stage is a word the program writes");
    check(graph.address(synth->channels[3].record) % 32 == 0,
          "a channel's record is aligned to its size");

    // the copies, which the wiring above never named: the voices and the
    // channels, each a vector loop, and the LFOs two of a shape, too few
    // for a loop
    std::vector<std::pair<int, bool>> copies;
    std::string found;
    for (const Graph::CopySet &set : graph.copy_sets()) {
        copies.push_back({set.copies, set.looped});
        found += (found.empty() ? "" : ", ") + std::to_string(set.copies)
                 + " of " + std::to_string(set.nodes) + " nodes"
                 + (set.looped ? " (a loop, " + std::to_string(set.rows)
                                         + " rows in its body)"
                               : "");
    }
    std::printf("the graph's copies: %s\n", found.c_str());
    std::sort(copies.begin(), copies.end());
    check(copies
                  == std::vector<std::pair<int, bool>>{{2, false},
                                                       {2, false},
                                                       {2, false},
                                                       {2, false},
                                                       {channel_count, true},
                                                       {voice_count, true}},
          "the graph finds its voices and its channels, and loops over them, and its pairs of LFOs");
    for (const Graph::CopySet &set : graph.copy_sets()) {
        if (set.looped) {
            check_equal(set.rows, set.copies == voice_count ? 23 : 17,
                        "the instruction rows in the loop body of "
                                + std::to_string(set.copies) + " copies");
        }
    }
    check_equal(
            static_cast<int64_t>(graph.initial_values().size()),
            channel_count + voice_count,
            "words the graph has the firmware set at load: a pointer to its sinks for each element");
    check(graph.writer(graph.initial_values().front().address)
                  == Graph::Writer::firmware,
          "such a word is the firmware's");

    // the set-up: the same performance on the model and on the interpreter
    csp::Processor processor;
    for (const performance::Write &write :
         performance::writes(*synth, performance::set_up(*synth))) {
        processor.write(write.address, write.raw);
    }
    for (const Graph::InitialValue &initial : graph.initial_values()) {
        processor.write(initial.address, initial.value);
    }
    auto evaluator = std::make_unique<csp::GraphEvaluator>(graph);
    for (const performance::Setting &setting : performance::set_up(*synth)) {
        set(*evaluator, setting);
    }
    start(processor, graphed.image);

    int differences = 0, early = 0, stale = 0, cycles = 0;
    const int passes = performance::passes;
    for (int at = 1; at <= passes; ++at) {
        // the performance: wires moved and notes played while it runs
        const performance::Settings changes =
                performance::before_pass(*synth, at);
        for (const performance::Write &write :
             performance::writes(*synth, changes)) {
            processor.write(write.address, write.raw);
        }
        processor.swap();
        const csp::PassReport report = processor.pass();
        for (const std::string &error : report.errors) {
            if (early++ < 3) {
                std::printf("  pass %d: %s\n", at, error.c_str());
            }
        }
        stale += static_cast<int>(report.stale_sinks.size());
        cycles = std::max(cycles, report.cycles);
        evaluator->pass();
        // the writes land in the model at the end of this pass, so the
        // interpreter takes them for the pass after
        if (report.writes_applied > 0) {
            for (const performance::Setting &setting : changes) {
                set(*evaluator, setting);
            }
        }
        for (const int address : evaluator->sink_addresses()) {
            const int32_t from_program =
                    processor.sink(address - csp::sink_base);
            const int32_t from_graph = evaluator->sink(address);
            if (from_program != from_graph && differences++ < 5) {
                std::printf(
                        "  pass %d, sink 0x%03x: the interpreter has %d, the "
                        "program %d\n",
                        at, address, from_graph, from_program);
            }
        }
    }
    check_equal(differences, 0,
                "sinks where the interpreter and the graph's program differ "
                "over " + std::to_string(passes)
                        + " passes");
    check_equal(early, 0, "reads before ready reported by the model");
    check_equal(stale, 0, "sinks the graph's program left unwritten");
    check_equal(cycles, graphed.cycles,
                "the model runs the cycles the builder counted");

    // the sinks are the layout's, and the comparison above was of all of
    // them: three for each voice, three for each channel
    const std::vector<int> sinks = evaluator->sink_addresses();
    auto has                     = [&](int address) {
        return std::find(sinks.begin(), sinks.end(), address) != sinks.end();
    };
    bool laid_out = true;
    for (int v = 0; v < voice_count; ++v) {
        for (const int k :
             {wiring::voice_sink::pitch, wiring::voice_sink::cutoff,
              wiring::voice_sink::gain}) {
            laid_out = laid_out
                       && has(wiring::voice_sink::base
                              + v * wiring::voice_sink::block + k);
        }
    }
    for (int c = 0; c < channel_count; ++c) {
        for (const int k :
             {wiring::channel_sink::duty_0, wiring::channel_sink::duty_1,
              wiring::channel_sink::resonance}) {
            laid_out = laid_out
                       && has(wiring::channel_sink::base
                              + c * wiring::channel_sink::block + k);
        }
    }
    check_equal(static_cast<int64_t>(sinks.size()),
                3LL * (voice_count + channel_count),
                "sinks: three for each voice and three for each channel");
    check(laid_out, "every sink is where wiring.hpp lays it out");

    // that the comparison is of live values: sinks move, and differ by voice
    const int32_t gain_1 = evaluator->sink(wiring::voice_sink::base
                                           + 1 * wiring::voice_sink::block
                                           + wiring::voice_sink::gain);
    const int32_t gain_2 = evaluator->sink(wiring::voice_sink::base
                                           + 2 * wiring::voice_sink::block
                                           + wiring::voice_sink::gain);
    check(gain_1 != 0 && gain_2 != 0 && gain_1 != gain_2,
          "the voices' gains are alive at the end");
}

// ---- the Noaidi by its formulas -------------------------------------------------

// The Noaidi wired and built, on the reference model, set by wire as the
// firmware sets it. A write is in the registers from the pass after the one
// it was sent before: the model applies the queue at a pass's end.
struct Played {
    std::unique_ptr<wiring::Synth> synth = std::make_unique<wiring::Synth>();
    std::unique_ptr<csp::ProgramBuilder::Built> built =
            std::make_unique<csp::ProgramBuilder::Built>();
    std::unique_ptr<csp::Processor> processor =
            std::make_unique<csp::Processor>();
    performance::Settings settings;

    bool wire_and_build(const std::string &what) {
        wiring::wire(*synth);
        if (!build(synth->graph, *built, what)) {
            return false;
        }
        for (const Graph::InitialValue &initial :
             synth->graph.initial_values()) {
            processor->write(initial.address, initial.value);
        }
        return true;
    }

    void word(Wire wire, double value) {
        settings.push_back(
                {performance::Setting::Kind::word, wire, q(value), {}});
    }
    void dword(Wire wire, double value) {
        settings.push_back(
                {performance::Setting::Kind::dword, wire, q_wide(value), {}});
    }
    void pointer(Wire wire, Record record) {
        settings.push_back(
                {performance::Setting::Kind::pointer, wire, 0, record});
    }
    void stage(Wire wire, Record segment) {
        settings.push_back(
                {performance::Setting::Kind::offset, wire, 0, segment});
    }
    void send() {
        for (const performance::Write &write :
             performance::writes(*synth, settings)) {
            processor->write(write.address, write.raw);
        }
        settings.clear();
        processor->swap();
    }

    double sink(int address) const {
        return processor->sink(address - csp::sink_base)
               / static_cast<double>(csp::word_one);
    }
    int address(Wire wire) const {
        return synth->graph.address(wire);
    }
};

// An LFO's wave at a phase, −8 … +8 a cycle.
double lfo_wave(int shape, double phase, double depth, double neg_depth,
                double gain) {
    switch (shape) {
    case wiring::shape_saw:
        return phase * gain;
    case wiring::shape_square:
        return phase < 0 ? depth : neg_depth;
    case wiring::shape_triangle:
        return std::fabs(phase) * gain + neg_depth;
    default: {
        const double p        = phase / 8;
        const double parabola = 4 * p * (1 - std::fabs(p));
        return (0.775 * parabola + 0.225 * parabola * std::fabs(parabola))
               * depth;
    }
    }
}

// Every sink by its formula, in floating point: the LFOs held at phases of
// their own, each channel listening to two of them by depths of its own, each
// voice on a channel with its levels held.
void test_the_noaidis_formulas() {
    Played played;
    if (!played.wire_and_build("the Noaidi, for its formulas")) {
        return;
    }
    const wiring::Synth &synth = *played.synth;

    // the LFOs step for five passes and then stand: one of them wraps
    constexpr int stepping_passes                        = 5;
    constexpr std::array<double, wiring::lfo_count> step = {
            1.8, -1.02, -0.64, -0.26, 0.12, 0.5, 0.88, 1.26};
    std::array<double, wiring::lfo_count> lfo_out;
    for (int k = 0; k < wiring::lfo_count; ++k) {
        const wiring::Lfo &lfo = synth.lfos[static_cast<size_t>(k)];
        const double depth     = 0.5 + 0.05 * k;
        const double neg_depth = -0.4 + 0.03 * k;
        const double gain      = 0.1 + 0.01 * k;
        played.dword(lfo.step, step[static_cast<size_t>(k)]);
        played.word(lfo.depth, depth);
        played.word(lfo.neg_depth, neg_depth);
        played.word(lfo.gain, gain);
        const double phase = std::remainder(
                stepping_passes * step[static_cast<size_t>(k)], 16.0);
        lfo_out[static_cast<size_t>(k)] = lfo_wave(
                k % wiring::lfo_shape_count, phase, depth, neg_depth, gain);
    }

    struct Channel {
        double bend, p1, c1, p2, c2, base, track, amount;
        int lfo1, lfo2;
        double d1, d2, r1, r2, duty0, duty1, resonance;
    };
    std::vector<Channel> channel(wiring::channel_count);
    for (int c = 0; c < wiring::channel_count; ++c) {
        Channel &a = channel[static_cast<size_t>(c)];
        a          = {0.02 * (c - 8),
                      0.1 + 0.01 * c,
                      -0.2 + 0.03 * c,
                      0.05 * (c % 4),
                      0.4 - 0.02 * c,
                      0.5 + 0.1 * (c % 5),
                      0.25 * (c % 5),
                      0.3 + 0.05 * c,
                      (3 * c) % wiring::lfo_count,
                      (7 * c + 5) % wiring::lfo_count,
                      0.03 * (c % 5),
                      -0.02 * (c % 3),
                      0.1 * (c % 4),
                      0.05 * (c % 6),
                      0.1 + 0.02 * c,
                      -0.3 + 0.03 * c,
                      0.5 + 0.1 * (c % 7)};
        // the first channels' resonance sinks are an LFO each, bare
        if (c < wiring::lfo_count) {
            a.lfo1      = c;
            a.r1        = 1.0;
            a.r2        = 0;
            a.resonance = 0;
        }
        const wiring::Channel &wired = synth.channels[static_cast<size_t>(c)];
        played.pointer(wired.lfo[0],
                       synth.lfos[static_cast<size_t>(a.lfo1)].record);
        played.pointer(wired.lfo[1],
                       synth.lfos[static_cast<size_t>(a.lfo2)].record);
        played.word(wired.depth[0][wiring::moves_pitch], a.p1);
        played.word(wired.depth[1][wiring::moves_pitch], a.p2);
        played.word(wired.depth[0][wiring::moves_cutoff], a.c1);
        played.word(wired.depth[1][wiring::moves_cutoff], a.c2);
        played.word(wired.depth[0][wiring::moves_duty], a.d1);
        played.word(wired.depth[1][wiring::moves_duty], a.d2);
        played.word(wired.depth[0][wiring::moves_resonance], a.r1);
        played.word(wired.depth[1][wiring::moves_resonance], a.r2);
        played.word(wired.bend, a.bend);
        played.word(wired.cutoff_base, a.base);
        played.word(wired.key_track, a.track);
        played.word(wired.mod_amount, a.amount);
        played.word(wired.duty_base[0], a.duty0);
        played.word(wired.duty_base[1], a.duty1);
        played.word(wired.resonance_base, a.resonance);
    }

    struct Voice {
        double note, level_amp, level_mod, velocity;
        int channel;
    };
    std::vector<Voice> voice(wiring::voice_count);
    for (int v = 0; v < wiring::voice_count; ++v) {
        Voice &a = voice[static_cast<size_t>(v)];
        a = {-1.0 + 0.1 * v, 0.1 + 0.02 * v, 0.9 - 0.02 * v, 0.3 + 0.02 * v,
             (5 * v + 1) % wiring::channel_count};
        const wiring::Voice &wired = synth.voices[static_cast<size_t>(v)];
        played.pointer(wired.channel,
                       synth.channels[static_cast<size_t>(a.channel)].record);
        played.word(wired.note, a.note);
        played.word(wired.velocity[wiring::envelope_amp], a.velocity);
        played.word(wired.velocity[wiring::envelope_mod], 1.0);
        played.dword(wired.level[wiring::envelope_amp], a.level_amp);
        played.dword(wired.level[wiring::envelope_mod], a.level_mod);
        // in the decay, whose rate is 0: the levels stand
        for (int e = 0; e < wiring::envelope_count; ++e) {
            played.stage(wired.stage[static_cast<size_t>(e)],
                         synth.channels[0]
                                 .segments[static_cast<size_t>(e)]
                                          [wiring::stage_decay]
                                 .record);
        }
    }
    played.send();
    csp::Processor &processor = *played.processor;
    start(processor, played.built->image);

    // the write that stops the LFOs is in the registers after the pass it
    // was sent before, which is a step too
    for (int n = 1; n < stepping_passes; ++n) {
        pass(processor, "the Noaidi's formulas, stepping");
    }
    for (const wiring::Lfo &lfo : synth.lfos) {
        played.dword(lfo.step, 0);
    }
    played.send();
    pass(processor, "the Noaidi's formulas, the last step");
    check_equal(processor.queued_writes(), 0, "the LFOs' steps are written");
    for (int n = 0; n < 3; ++n) {
        pass(processor, "the Noaidi's formulas, standing");
    }

    double worst_lfo = 0;
    for (int k = 0; k < wiring::lfo_count; ++k) {
        const int sinks =
                wiring::channel_sink::base + wiring::channel_sink::block * k;
        worst_lfo = std::max(
                worst_lfo,
                std::fabs(played.sink(sinks + wiring::channel_sink::resonance)
                          - lfo_out[static_cast<size_t>(k)]));
    }
    // a few raw units of the words' rounding, through the sine's eight products
    check(worst_lfo <= 4.0 / csp::word_one,
          "every LFO's wave is its shape's formula at its phase: largest difference "
                  + std::to_string(worst_lfo));

    double worst_channel = 0;
    for (int c = 0; c < wiring::channel_count; ++c) {
        const Channel &a     = channel[static_cast<size_t>(c)];
        const double lfo1    = lfo_out[static_cast<size_t>(a.lfo1)];
        const double lfo2    = lfo_out[static_cast<size_t>(a.lfo2)];
        const double duty    = lfo1 * a.d1 + lfo2 * a.d2;
        const double want[3] = {a.duty0 + duty, a.duty1 + duty,
                                a.resonance + lfo1 * a.r1 + lfo2 * a.r2};
        const int fields[3]  = {wiring::channel_sink::duty_0,
                                wiring::channel_sink::duty_1,
                                wiring::channel_sink::resonance};
        const int sinks =
                wiring::channel_sink::base + wiring::channel_sink::block * c;
        for (int k = 0; k < 3; ++k) {
            worst_channel = std::max(
                    worst_channel,
                    std::fabs(played.sink(sinks + fields[k]) - want[k]));
        }
    }
    check(worst_channel <= 6.0 / csp::word_one,
          "the channels' pulse width and resonance sinks match their formulas: largest difference "
                  + std::to_string(worst_channel));

    double worst_voice = 0;
    for (int v = 0; v < wiring::voice_count; ++v) {
        const Voice &a             = voice[static_cast<size_t>(v)];
        const Channel &c           = channel[static_cast<size_t>(a.channel)];
        const double lfo1          = lfo_out[static_cast<size_t>(c.lfo1)];
        const double lfo2          = lfo_out[static_cast<size_t>(c.lfo2)];
        const double channel_pitch = c.bend + lfo1 * c.p1 + lfo2 * c.p2;
        // the cutoff tracks the bend and the note, not the pitch LFOs: an
        // LFO on the pitch does not sweep the filter too
        const double channel_cutoff =
                c.base + lfo1 * c.c1 + lfo2 * c.c2 + c.track * c.bend;
        const double want[3] = {a.note + channel_pitch,
                                4 * a.level_mod * c.amount + a.note * c.track
                                        + channel_cutoff,
                                a.level_amp * a.velocity};
        const int fields[3]  = {wiring::voice_sink::pitch,
                                wiring::voice_sink::cutoff,
                                wiring::voice_sink::gain};
        const int sinks =
                wiring::voice_sink::base + wiring::voice_sink::block * v;
        for (int k = 0; k < 3; ++k) {
            worst_voice = std::max(
                    worst_voice,
                    std::fabs(played.sink(sinks + fields[k]) - want[k]));
        }
    }
    // the mod envelope's term is multiplied by 4
    check(worst_voice <= 16.0 / csp::word_one,
          "the voices' pitch, cutoff and gain sinks match their formulas: largest difference "
                  + std::to_string(worst_voice));
}

// An envelope from a note on to its release, pass for pass by its formula:
// the level goes a rate's share of its distance to the segment's target, and
// the attack ends in the decay when the level is full.
void test_the_noaidis_envelope() {
    Played played;
    if (!played.wire_and_build("the Noaidi, for an envelope")) {
        return;
    }
    const wiring::Synth &synth     = *played.synth;
    const wiring::Channel &channel = synth.channels[0];
    constexpr int amp              = wiring::envelope_amp;
    // attack to 1.3 × full, decay to a sustain of 0.5, release to 0
    constexpr std::array<double, wiring::stage_count> target = {1.3, 0.5, 0.0};
    constexpr std::array<double, wiring::stage_count> rate = {0.1, 0.05, 0.05};
    for (int e = 0; e < wiring::envelope_count; ++e) {
        for (int s = 0; s < wiring::stage_count; ++s) {
            const wiring::Segment &segment =
                    channel.segments[static_cast<size_t>(e)]
                                    [static_cast<size_t>(s)];
            played.dword(segment.target, target[static_cast<size_t>(s)]);
            played.dword(segment.rate, rate[static_cast<size_t>(s)]);
        }
    }
    auto segment_of = [&](int e, int stage) {
        return channel
                .segments[static_cast<size_t>(e)][static_cast<size_t>(stage)]
                .record;
    };
    // every voice idle on the channel, in release at zero; the first struck
    for (const wiring::Voice &voice : synth.voices) {
        played.pointer(voice.channel, channel.record);
        for (int e = 0; e < wiring::envelope_count; ++e) {
            played.word(voice.velocity[static_cast<size_t>(e)], 1.0);
            played.stage(voice.stage[static_cast<size_t>(e)],
                         segment_of(e, wiring::stage_release));
        }
    }
    const wiring::Voice &struck = synth.voices[0];
    const wiring::Voice &idle   = synth.voices[1];
    played.stage(struck.stage[amp], segment_of(amp, wiring::stage_attack));
    played.send();
    csp::Processor &processor = *played.processor;
    start(processor, played.built->image);

    const Graph &graph = synth.graph;
    auto offset_of     = [&](int stage) {
        return graph.offset(segment_of(amp, stage));
    };
    auto gain_of = [&](int v) {
        return played.sink(wiring::voice_sink::base
                           + wiring::voice_sink::block * v
                           + wiring::voice_sink::gain);
    };

    // the formula, beside the model
    int stage      = wiring::stage_attack;
    double level   = 0;
    double worst   = 0;
    double highest = 0;
    auto one_pass  = [&](const std::string &what) {
        pass(processor, what);
        if (level >= 1.0) {
            stage = std::max(stage, static_cast<int>(wiring::stage_decay));
        }
        level += (target[static_cast<size_t>(stage)] - level)
                 * rate[static_cast<size_t>(stage)];
        worst   = std::max(worst, std::fabs(gain_of(0) - level));
        highest = std::max(highest, level);
    };
    auto stage_word = [&] {
        return processor.read(played.address(struck.stage[amp]));
    };

    int passes_to_decay = 0;
    while (passes_to_decay < 200
           && stage_word() == offset_of(wiring::stage_attack)) {
        one_pass("the attack");
        ++passes_to_decay;
    }
    check_equal(stage_word(), offset_of(wiring::stage_decay),
                "the attack ends in the decay");
    check_equal(stage, wiring::stage_decay, "in the pass the formula says");
    check(highest >= 1.0, "with the level at full scale");
    check_equal(processor.read(played.address(idle.stage[amp])),
                offset_of(wiring::stage_release),
                "a voice never struck stays in release");
    check_equal(processor.read_wide(played.address(idle.level[amp])), 0,
                "at zero");

    for (int n = 0; n < 400; ++n) {
        one_pass("the decay");
    }
    check(std::fabs(gain_of(0) - 0.5) < 0.001,
          "the decay settles at the sustain level");

    // struck again while it sounds: the level climbs on from where it is
    played.stage(struck.stage[amp], segment_of(amp, wiring::stage_attack));
    played.send();
    one_pass("the note on lands");
    stage = wiring::stage_attack;
    one_pass("struck again");
    check_equal(stage_word(), offset_of(wiring::stage_attack),
                "a voice struck again is in the attack");
    check(gain_of(0) > 0.5 && gain_of(0) < 1.0,
          "and climbs on from the sustain level: "
                  + std::to_string(gain_of(0)));
    for (int n = 0; n < 100 && stage_word() == offset_of(wiring::stage_attack);
         ++n) {
        one_pass("the second attack");
    }
    check_equal(stage_word(), offset_of(wiring::stage_decay),
                "and ends in the decay at full scale");

    // let go: the firmware writes the release, and the program leaves it
    played.stage(struck.stage[amp], segment_of(amp, wiring::stage_release));
    played.send();
    one_pass("the note off lands");
    stage = wiring::stage_release;
    for (int n = 0; n < 400; ++n) {
        one_pass("the release");
    }
    check_equal(stage_word(), offset_of(wiring::stage_release),
                "let go: the program leaves the release alone");
    check(gain_of(0) < 0.001, "the release falls to zero");
    check(worst <= 2.0 / csp::word_one,
          "the gain sink follows the envelope's formula pass for pass: largest difference "
                  + std::to_string(worst));
}

} // namespace

int main() {
    test_operators();
    test_refusals();
    test_a_field_summed_onto();
    constexpr int body_rows = 20; // of test_copies' circuit as a loop
    test_copies(16, true, body_rows);
    test_copies(32, true, body_rows);
    test_copies(9, true, body_rows);
    test_copies(8, false, 0);  // too few for a round
    test_copies(20, false, 0); // a round of sixteen and one of four
    test_a_copy_made_otherwise();
    test_copies_that_point_at_each_other();
    test_the_interpreter();
    test_todays_synth();
    test_the_noaidis_formulas();
    test_the_noaidis_envelope();
    std::printf("dsp graph: %s (%d checks, %d failures)\n",
                failures ? "FAIL" : "ALL PASS", checks, failures);
    return failures ? 1 : 0;
}
