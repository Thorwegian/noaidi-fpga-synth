// dsp_graph_test.cpp — host tests for the DSP graph (app/main/csp/dsp_graph.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Three things. Each operator and each kind of connection in a small graph,
// its image run on the reference model beside the graph's interpreter
// (graph_evaluator.hpp), every value checked as it was worked out by hand and
// every sink equal in both. And the Noaidi's wiring (app/main/sound_engine.cpp: 8
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
#include "sound_engine.hpp"

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

// A select whose compare reads a word through a pointer and whose operand is
// another select's result. The one compares the loop's own word, the other a
// word the pointer holds: in the open group the pointer's compare ranks above
// the one it does not, though the select it sets the flags for waits on the
// other compare's. Sixteen copies are a loop and its body orders; two and
// eight are straight-line code. Every sink has the value worked out here.
void test_a_nested_select(int count, bool looped, int body_rows) {
    const std::string what = std::to_string(count) + " nested selects";
    auto a_of              = [](int c) {
        return 0.125 * (1 + c % 4);
    };
    auto b_of = [](int c) {
        return 0.125 * (2 + c % 5);
    };
    auto knob_of = [](int c) {
        return 0.25 * (1 + c % 3);
    };

    Graph graph;
    struct Knob {
        Wire word;
        Record record;
    };
    std::vector<Knob> knobs(static_cast<size_t>(count));
    std::vector<Record> records;
    for (Knob &knob : knobs) {
        knob.word = graph.source();
        const std::vector<Field> fields{knob.word};
        knob.record = graph.record(fields);
        records.push_back(knob.record);
    }
    struct Copy {
        Wire a, b, pointer;
    };
    std::vector<Copy> copies(static_cast<size_t>(count));
    for (int c = 0; c < count; ++c) {
        Copy &copy         = copies[static_cast<size_t>(c)];
        copy.a             = graph.source();
        copy.b             = graph.source();
        copy.pointer       = graph.pointer(records);
        const Wire knob    = graph.through(copy.pointer, 0);
        const Wire product = graph.multiply(copy.a, knob);
        // the product is the loop's own word: this compare is outside the group
        const Wire first = graph.select(
                product, copy.b, csp::Condition::negative, product, copy.b);
        // the knob is read through the pointer, and the first's result is an
        // operand: this compare is in the group, that one is not
        const Wire second = graph.select(knob, copy.b, csp::Condition::negative,
                                         first, copy.a);
        graph.sink(csp::sink_base + 2 * c + 0, second);
        graph.sink(csp::sink_base + 2 * c + 1, first);
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

    auto processor = std::make_unique<csp::Processor>();
    csp::GraphEvaluator evaluator(graph);
    auto word = [&](Wire wire, int32_t raw) {
        processor->write(graph.address(wire), raw);
        evaluator.set_word(wire, raw);
    };
    auto point_model = [&](int moved) {
        for (int c = 0; c < count; ++c) {
            evaluator.set_pointer(
                    copies[static_cast<size_t>(c)].pointer,
                    knobs[static_cast<size_t>((c + moved) % count)].record);
        }
    };
    auto point_graph = [&](int moved) {
        for (int c = 0; c < count; ++c) {
            processor->write(
                    graph.address(copies[static_cast<size_t>(c)].pointer),
                    graph.address(
                            knobs[static_cast<size_t>((c + moved) % count)]
                                    .record));
        }
    };
    for (int c = 0; c < count; ++c) {
        word(knobs[static_cast<size_t>(c)].word, q(knob_of(c)));
        word(copies[static_cast<size_t>(c)].a, q(a_of(c)));
        word(copies[static_cast<size_t>(c)].b, q(b_of(c)));
    }
    for (const Graph::InitialValue &initial : graph.initial_values()) {
        processor->write(initial.address, initial.value);
    }
    point_model(0);
    point_graph(0);
    start(*processor, built.image);

    auto expect = [&](int moved) {
        int wrong = 0;
        for (int c = 0; c < count; ++c) {
            const double a = a_of(c), b = b_of(c);
            const double knob    = knob_of((c + moved) % count);
            const double product = a * knob;
            const double first   = product - b < 0 ? b : product;
            // if_set when x − y has the condition: the knob − b select takes
            // a when it does, and the first's result otherwise
            const double want[] = {knob - b < 0 ? a : first, first};
            for (int k = 0; k < 2; ++k) {
                const int32_t got = processor->sink(2 * c + k);
                if (got != q(want[k]) && wrong++ < 3) {
                    std::printf("  %s, copy %d sink %d: %d, want %d\n",
                                what.c_str(), c, k, got, q(want[k]));
                }
            }
        }
        return wrong;
    };
    for (int warm = 0; warm < 2; ++warm) {
        pass(*processor, what);
        evaluator.pass();
    }
    check_equal(expect(0), 0, what + ": sinks that are wrong");
    compare_sinks(evaluator, *processor, what);
    point_model(1); // every pointer moved
    processor->swap();
    // the writes land a share a pass, the first at the end of this one: the
    // interpreter takes them all at once, so the sinks are compared once the
    // chip's pointers have all landed
    pass(*processor, what);
    evaluator.pass();
    point_graph(1);
    processor->swap(); // the firmware's swap: the writes are the program's now
    while (processor->queued_writes() > 0) {
        pass(*processor, what);
        evaluator.pass();
    }
    for (int settled = 0; settled < 2; ++settled) {
        pass(*processor, what);
        evaluator.pass();
    }
    check_equal(expect(1), 0,
                what + ": sinks that are wrong, the pointers moved");
    compare_sinks(evaluator, *processor, what);
}

// ---- every select's own compare -----------------------------------------------------
//
// A wiring may hold as many selects as it needs, each comparing a word with
// an operand of its own — a word the firmware writes, or an immediate in the
// row — and each answers the compare it was built with, whatever order the
// rows issue in and whichever way the others answer. A select answering
// another's compare would show here as one arm of one compare, twice.
//
// The shape a copy picks with is a word the compare reads through a pointer:
// with a word operand the compare and the select share the pointer's index
// register, and with an immediate the compare reads no register but the
// pointed word, so the two are not in a group together.
//
// The number in a row is a raw Q4.14 word: graph.constant(q(1.0)) is the word
// 16384, and graph.constant(1) is the word 1 — 2^-14, a little above zero,
// not 1.0.

void test_selects_against_their_own_compares(int compares, bool words,
                                             int copies) {
    const std::string what = std::to_string(compares) + " compares against "
                             + (words ? "words" : "immediates") + ", "
                             + std::to_string(copies)
                             + (copies == 1 ? " copy" : " copies");
    const double limit[] = {1.0, 2.0, 3.0};
    auto if_clear_of     = [](int k) {
        return -0.25 * (k + 1);
    };
    auto if_set_of = [](int k) {
        return 0.25 * (k + 1);
    };

    Graph graph;
    std::vector<Wire> limits; // the thresholds, when they are words
    for (int k = 0; k < compares; ++k) {
        limits.push_back(graph.source());
    }
    struct Copy {
        Wire shape;
        Wire pointer;
        Record record;
        Wire if_clear[3], if_set[3];
    };
    std::vector<Copy> pickers(static_cast<size_t>(copies));
    std::vector<Record> records;
    for (Copy &copy : pickers) {
        copy.shape = graph.source();
        for (int k = 0; k < compares; ++k) {
            copy.if_clear[k] = graph.source();
            copy.if_set[k]   = graph.source();
        }
        const std::vector<Field> fields{copy.shape};
        copy.record = graph.record(fields);
        records.push_back(copy.record);
    }
    for (int c = 0; c < copies; ++c) {
        Copy &copy         = pickers[static_cast<size_t>(c)];
        copy.pointer       = graph.pointer(records);
        const Wire through = graph.through(copy.pointer, 0);
        for (int k = 0; k < compares; ++k) {
            const Wire operand = words ? limits[static_cast<size_t>(k)]
                                       : graph.constant(q(limit[k]));
            const Wire picked =
                    graph.select(through, operand, csp::Condition::negative,
                                 copy.if_clear[k], copy.if_set[k]);
            graph.sink(csp::sink_base + 4 * c + k, picked);
        }
    }

    csp::ProgramBuilder::Built built;
    if (!build(graph, built, what)) {
        return;
    }
    for (const Graph::CopySet &set : graph.copy_sets()) {
        if (set.copies == copies) {
            check(set.looped == (copies >= csp::result_latency),
                  what
                          + (copies >= csp::result_latency
                                     ? " are a vector loop"
                                     : " are straight-line code"));
        }
    }

    // The rows the compares came out as: every immediate is the word the
    // graph was given with it, and no compare against a word reads one.
    std::vector<int32_t> immediates;
    int compares_in_the_image = 0;
    for (int row = 0; row < built.image.length; ++row) {
        const csp::Word word = csp::Word::decode(built.image.rows[row]);
        const csp::Control control =
                csp::Control::decode(built.image.rom[word.op]);
        if (!(control
              == csp::control_of(csp::Op::cmp, false, csp::ASource::zero))) {
            continue;
        }
        ++compares_in_the_image;
        if (words) {
            check(word.x.mode != csp::Operand::Mode::immediate
                          && word.y.mode != csp::Operand::Mode::immediate,
                  what + ": a compare against words carries no immediate");
        } else {
            immediates.push_back(static_cast<int32_t>(word.imm));
        }
    }
    check(compares_in_the_image >= compares,
          what + ": every compare has a row");
    if (!words) {
        for (int k = 0; k < compares; ++k) {
            check(std::find(immediates.begin(), immediates.end(), q(limit[k]))
                          != immediates.end(),
                  what + ": the row's immediate is the word given, "
                          + std::to_string(q(limit[k])));
        }
    }

    auto processor = std::make_unique<csp::Processor>();
    csp::GraphEvaluator evaluator(graph);
    auto word = [&](Wire wire, int32_t raw) {
        processor->write(graph.address(wire), raw);
        evaluator.set_word(wire, raw);
    };
    for (int c = 0; c < copies; ++c) {
        Copy &copy = pickers[static_cast<size_t>(c)];
        processor->write(graph.address(copy.pointer),
                         graph.address(copy.record));
        evaluator.set_pointer(copy.pointer, copy.record);
        for (int k = 0; k < compares; ++k) {
            word(copy.if_clear[k], q(if_clear_of(k)));
            word(copy.if_set[k], q(if_set_of(k)));
        }
    }
    for (int k = 0; k < compares; ++k) {
        word(limits[static_cast<size_t>(k)], q(limit[k]));
    }
    for (const Graph::InitialValue &initial : graph.initial_values()) {
        processor->write(initial.address, initial.value);
    }
    start(*processor, built.image);

    // the shape swept through every threshold and past the last
    int wrong = 0;
    for (int step = -2; step <= 16; ++step) {
        const double shape = 0.25 * step;
        for (int c = 0; c < copies; ++c) {
            word(pickers[static_cast<size_t>(c)].shape, q(shape));
        }
        processor->swap();
        pass(*processor, what); // the writes land at the end of this pass
        evaluator.pass();
        pass(*processor, what);
        evaluator.pass();
        for (int c = 0; c < copies; ++c) {
            for (int k = 0; k < compares; ++k) {
                const double want =
                        shape < limit[k] ? if_set_of(k) : if_clear_of(k);
                const int32_t got = processor->sink(4 * c + k);
                if (got != q(want) && wrong++ < 3) {
                    std::printf("  %s, copy %d compare %d at %+.2f: %d, want "
                                "%d\n",
                                what.c_str(), c, k, shape, got, q(want));
                }
            }
        }
        compare_sinks(evaluator, *processor, what);
    }
    check_equal(wrong, 0, what + ": selects that answered another compare");
}

// A constant is the raw word the graph is given and nothing else: the word 1
// is 2^-14, so a wiring that compares against 1.0 says q(1.0) — 16384, and one
// that says graph.constant(1) compares against a little above zero. Two
// selects, one of each, over a shape of 0.5: the raw word's compare is not
// negative, the scaled one's is.
void test_a_constant_is_the_word_it_says() {
    const std::string what = "a constant is the word it says";
    Graph graph;
    const Wire shape  = graph.source();
    const Wire above  = graph.source(); // +1.0, the if_set arm
    const Wire below  = graph.source(); // −1.0, the if_clear arm
    const Wire raw    = graph.select(shape, graph.constant(1),
                                     csp::Condition::negative, below, above);
    const Wire scaled = graph.select(shape, graph.constant(q(1.0)),
                                     csp::Condition::negative, below, above);
    graph.sink(csp::sink_base + 0, raw);
    graph.sink(csp::sink_base + 1, scaled);

    csp::ProgramBuilder::Built built;
    if (!build(graph, built, what)) {
        return;
    }
    auto processor = std::make_unique<csp::Processor>();
    csp::GraphEvaluator evaluator(graph);
    for (const Graph::InitialValue &initial : graph.initial_values()) {
        processor->write(initial.address, initial.value);
    }
    processor->write(graph.address(shape), q(0.5));
    processor->write(graph.address(above), q(1.0));
    processor->write(graph.address(below), q(-1.0));
    evaluator.set_word(shape, q(0.5));
    evaluator.set_word(above, q(1.0));
    evaluator.set_word(below, q(-1.0));
    start(*processor, built.image);
    pass(*processor, what);
    evaluator.pass();

    check_equal(processor->sink(0), q(-1.0),
                what + ": the word 1 is 2^-14, below a shape of 0.5");
    check_equal(processor->sink(1), q(1.0),
                what + ": the word 16384 is 1.0, above a shape of 0.5");
    compare_sinks(evaluator, *processor, what);
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
// The synth the sound engine wires (app/main/sound_engine.cpp) and the performance it
// plays (tools/csp/performance.hpp): the settings on a processor, which runs
// the graph's program, and on the interpreter, which reads the graph itself.
// Every sink the graph has is checked, pass for pass.

using Wiring = SoundEngine::Wiring;

constexpr int channel_count = SoundEngine::channel_count;
constexpr int voice_count   = SoundEngine::voice_count;

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

// The performance on the model, which runs the graph's program, and on the
// interpreter, which reads the graph itself: every sink the graph has,
// compared pass for pass.
struct Performed {
    std::unique_ptr<csp::GraphEvaluator> evaluator;
    int differences = 0; // sinks where the two differ
    int early       = 0; // reads before ready, as the model reports them
    int stale       = 0; // sinks the program left unwritten
    int cycles      = 0; // of the longest pass
};

Performed perform(const SoundEngine &synth,
                  const csp::ProgramBuilder::Built &graphed) {
    const Graph &graph = synth.graph();
    Performed performed;
    // the set-up: the same performance on the model and on the interpreter
    csp::Processor processor;
    for (const performance::Write &write :
         performance::writes(synth, performance::set_up(synth))) {
        processor.write(write.address, write.raw);
    }
    for (const Graph::InitialValue &initial : graph.initial_values()) {
        processor.write(initial.address, initial.value);
    }
    performed.evaluator = std::make_unique<csp::GraphEvaluator>(graph);
    csp::GraphEvaluator &evaluator = *performed.evaluator;
    for (const performance::Setting &setting : performance::set_up(synth)) {
        set(evaluator, setting);
    }
    start(processor, graphed.image);

    for (int at = 1; at <= performance::passes; ++at) {
        // the performance: wires moved and notes played while it runs
        const performance::Settings changes =
                performance::before_pass(synth, at);
        for (const performance::Write &write :
             performance::writes(synth, changes)) {
            processor.write(write.address, write.raw);
        }
        processor.swap();
        const csp::PassReport report = processor.pass();
        for (const std::string &error : report.errors) {
            if (performed.early++ < 3) {
                std::printf("  pass %d: %s\n", at, error.c_str());
            }
        }
        performed.stale += static_cast<int>(report.stale_sinks.size());
        performed.cycles = std::max(performed.cycles, report.cycles);
        evaluator.pass();
        // the writes land in the model at the end of this pass, so the
        // interpreter takes them for the pass after
        if (report.writes_applied > 0) {
            for (const performance::Setting &setting : changes) {
                set(evaluator, setting);
            }
        }
        for (const int address : evaluator.sink_addresses()) {
            const int32_t from_program =
                    processor.sink(address - csp::sink_base);
            const int32_t from_graph = evaluator.sink(address);
            if (from_program != from_graph && performed.differences++ < 5) {
                std::printf(
                        "  pass %d, sink 0x%03x: the interpreter has %d, the "
                        "program %d\n",
                        at, address, from_graph, from_program);
            }
        }
    }
    return performed;
}

void check_performed(const Performed &performed,
                     const csp::ProgramBuilder::Built &graphed,
                     const std::string &what) {
    check_equal(performed.differences, 0,
                what
                        + ": sinks where the interpreter and the graph's "
                          "program differ over "
                        + std::to_string(performance::passes) + " passes");
    check_equal(performed.early, 0,
                what + ": reads before ready reported by the model");
    check_equal(performed.stale, 0,
                what + ": sinks the graph's program left unwritten");
    check_equal(performed.cycles, graphed.cycles,
                what + ": the model runs the cycles the builder counted");
}

void test_todays_synth() {
    performance::Unplayed link;
    auto synth = std::make_unique<SoundEngine>(link);
    synth->wire(Wiring::Paths::every());
    Graph &graph = synth->graph();
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

    check(graph.writer(graph.address(synth->wiring().voices[5].note))
                  == Graph::Writer::firmware,
          "a voice's note is the firmware's word");
    check(graph.writer(graph.address(synth->wiring().voices[5].stage[1]))
                  == Graph::Writer::program,
          "a voice's stage is a word the program writes");
    check(graph.address(synth->wiring().channels[3].record) % 32 == 0,
          "a channel's record is aligned to its size");

    // the copies, which the wiring above never named: the voices and the
    // channels, each a vector loop, and the LFOs' records, which are words
    // of their own a channel reads through a pointer
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
                  == std::vector<std::pair<int, bool>>{{channel_count, true},
                                                       {voice_count, true}},
          "the graph finds its voices and its channels, and loops over them");
    for (const Graph::CopySet &set : graph.copy_sets()) {
        if (set.looped) {
            // a voice's body: its two envelopes, its pitch, cutoff and
            // gain; a channel's: its two LFOs' phases and waves, and what
            // they move
            check_equal(set.rows, set.copies == voice_count ? 23 : 59,
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

    const Performed performed = perform(*synth, graphed);
    check_performed(performed, graphed, "every path");
    const csp::GraphEvaluator *evaluator = performed.evaluator.get();
    // the sinks are the layout's, and the comparison above was of all of
    // them: three for each voice, three for each channel
    const std::vector<int> sinks = evaluator->sink_addresses();
    auto has                     = [&](int address) {
        return std::find(sinks.begin(), sinks.end(), address) != sinks.end();
    };
    bool laid_out = true;
    for (int v = 0; v < voice_count; ++v) {
        for (const int k : {Wiring::VoiceSink::pitch, Wiring::VoiceSink::cutoff,
                            Wiring::VoiceSink::gain}) {
            laid_out = laid_out
                       && has(Wiring::VoiceSink::base
                              + v * Wiring::VoiceSink::block + k);
        }
    }
    for (int c = 0; c < channel_count; ++c) {
        for (const int k :
             {Wiring::ChannelSink::duty_0, Wiring::ChannelSink::duty_1,
              Wiring::ChannelSink::resonance}) {
            laid_out = laid_out
                       && has(Wiring::ChannelSink::base
                              + c * Wiring::ChannelSink::block + k);
        }
    }
    check_equal(static_cast<int64_t>(sinks.size()),
                3LL * (voice_count + channel_count),
                "sinks: three for each voice and three for each channel");
    check(laid_out, "every sink is where the engine lays it out");

    // that the comparison is of live values: sinks move, and differ by voice
    const int32_t gain_1 = evaluator->sink(Wiring::VoiceSink::base
                                           + 1 * Wiring::VoiceSink::block
                                           + Wiring::VoiceSink::gain);
    const int32_t gain_2 = evaluator->sink(Wiring::VoiceSink::base
                                           + 2 * Wiring::VoiceSink::block
                                           + Wiring::VoiceSink::gain);
    check(gain_1 != 0 && gain_2 != 0 && gain_1 != gain_2,
          "the voices' gains are alive at the end");
}

// The synth wired for some of its paths. A wiring with fewer paths is
// another graph and another program, with its own copies, layout and order,
// so each is played on the model against the interpreter of its graph, as
// the whole one is above.
void test_fewer_paths() {
    // a bit for each of what a channel's LFO moves (pitch, cutoff, pulse
    // width, resonance), a set for each of its two
    struct Case {
        const char *name;
        unsigned moves_1, moves_2;
    };
    const Case cases[] = {
            {"no LFO", 0b0000, 0b0000},
            {"LFO 1 onto the pitch", 0b0001, 0b0000},
            {"LFO 1 onto the cutoff", 0b0010, 0b0000},
            {"LFO 1 onto the pulse width", 0b0100, 0b0000},
            {"LFO 1 onto the resonance", 0b1000, 0b0000},
            {"LFO 2 alone, onto the pitch", 0b0000, 0b0001},
            {"both onto the pitch", 0b0001, 0b0001},
            {"onto the resonance and the pulse width", 0b1000, 0b0100},
            {"LFO 1 everywhere", 0b1111, 0b0000},
            {"two each", 0b0011, 0b0011},
            {"every path but the resonances'", 0b0111, 0b0111},
    };
    for (const Case &wiring : cases) {
        Wiring::Paths paths;
        paths.moves[0] = wiring.moves_1;
        paths.moves[1] = wiring.moves_2;
        performance::Unplayed link;
        auto synth = std::make_unique<SoundEngine>(link);
        synth->wire(paths);
        const auto graphed = std::make_unique<csp::ProgramBuilder::Built>();
        if (!build(synth->graph(), *graphed, wiring.name)) {
            continue;
        }
        std::printf("%s: %d rows, %d decode rows, %d cycles a pass\n",
                    wiring.name, graphed->image.length, graphed->image.rom_used,
                    graphed->cycles);
        check(graphed->cycles <= csp::pass_cycle_limit,
              std::string(wiring.name) + ": the program fits the pass");
        check_performed(perform(*synth, *graphed), *graphed, wiring.name);
    }
}

// ---- the Noaidi by its formulas -------------------------------------------------

// The Noaidi wired and built, on the reference model, set by wire as the
// firmware sets it. A write is in the registers from the pass after the one
// it was sent before: the model applies the queue at a pass's end.
struct Played {
    performance::Unplayed link;
    std::unique_ptr<SoundEngine> synth = std::make_unique<SoundEngine>(link);
    std::unique_ptr<csp::ProgramBuilder::Built> built =
            std::make_unique<csp::ProgramBuilder::Built>();
    std::unique_ptr<csp::Processor> processor =
            std::make_unique<csp::Processor>();
    performance::Settings settings;

    bool wire_and_build(const std::string &what) {
        synth->wire(Wiring::Paths::every());
        if (!build(synth->graph(), *built, what)) {
            return false;
        }
        for (const Graph::InitialValue &initial :
             synth->graph().initial_values()) {
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
        return synth->graph().address(wire);
    }
};

// A wave at a phase, −8 … +8 a cycle, in floating point.
double lfo_wave(int shape, double phase) {
    switch (shape) {
    case Wiring::shape_saw:
        return phase / 8;
    case Wiring::shape_square:
        return phase < 0 ? -1.0 : 1.0;
    case Wiring::shape_triangle:
        return std::fabs(phase) / 4 - 1.0;
    default: {
        // a parabola and a correction by its own square
        const double p        = phase / 8;
        const double parabola = 4 * p * (1 - std::fabs(p));
        return 0.775 * parabola + 0.225 * parabola * std::fabs(parabola);
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
    const SoundEngine &synth = *played.synth;

    // the LFOs step for five passes and then stand, each by a step and a
    // shape of its own: its phase wraps where the steps carry it past a cycle
    constexpr int stepping_passes = 5;
    auto step_of                  = [](int c, int l) {
        return -1.4 + 0.19 * (2 * c + l);
    };
    auto shape_of = [](int c, int l) {
        return l;
    };
    std::array<double, Wiring::lfo_count> lfo_out;
    for (int c = 0; c < SoundEngine::channel_count; ++c) {
        const Wiring::Channel &wired =
                synth.wiring().channels[static_cast<size_t>(c)];
        for (int l = 0; l < Wiring::channel_lfo_count; ++l) {
            const Wiring::Lfo &lfo = synth.wiring().lfo(c, l);
            const double step      = step_of(c, l);
            played.dword(lfo.step, step);
            played.word(lfo.shape, shape_of(c, l));
            played.pointer(wired.lfo[static_cast<size_t>(l)], lfo.record);
        }
    }
    // the square's high level, 1.0, for every LFO
    played.word(synth.wiring().one, 1.0);

    struct Channel {
        double bend, p1, c1, p2, c2, base, track, amount;
        double d1, d2, r1, r2, duty0, duty1, resonance;
    };
    std::vector<Channel> channel(SoundEngine::channel_count);
    for (int c = 0; c < SoundEngine::channel_count; ++c) {
        Channel &a = channel[static_cast<size_t>(c)];
        a          = {0.02 * (c - 8),  0.1 + 0.01 * c,  -0.2 + 0.03 * c,
                      0.05 * (c % 4),  0.4 - 0.02 * c,  0.5 + 0.1 * (c % 5),
                      0.25 * (c % 5),  0.3 + 0.05 * c,  0.03 * (c % 5),
                      -0.02 * (c % 3), 0.1 * (c % 4),   0.05 * (c % 6),
                      0.1 + 0.02 * c,  -0.3 + 0.03 * c, 0.5 + 0.1 * (c % 7)};
        const Wiring::Channel &wired =
                synth.wiring().channels[static_cast<size_t>(c)];
        const Wiring::Lfo &first  = synth.wiring().lfo(c, 0);
        const Wiring::Lfo &second = synth.wiring().lfo(c, 1);
        played.word(first.depth[Wiring::moves_pitch], a.p1);
        played.word(second.depth[Wiring::moves_pitch], a.p2);
        played.word(first.depth[Wiring::moves_cutoff], a.c1);
        played.word(second.depth[Wiring::moves_cutoff], a.c2);
        // each LFO's wave bare: LFO 1 on the resonance and LFO 2 on the
        // pulse width, so that a channel's sinks say what its two are
        played.word(first.depth[Wiring::moves_duty], 0.0);
        played.word(second.depth[Wiring::moves_duty], 1.0);
        played.word(first.depth[Wiring::moves_resonance], 1.0);
        played.word(second.depth[Wiring::moves_resonance], 0.0);
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
    std::vector<Voice> voice(SoundEngine::voice_count);
    for (int v = 0; v < SoundEngine::voice_count; ++v) {
        Voice &a = voice[static_cast<size_t>(v)];
        a = {-1.0 + 0.1 * v, 0.1 + 0.02 * v, 0.9 - 0.02 * v, 0.3 + 0.02 * v,
             (5 * v + 1) % SoundEngine::channel_count};
        const Wiring::Voice &wired =
                synth.wiring().voices[static_cast<size_t>(v)];
        played.pointer(
                wired.channel,
                synth.wiring().channels[static_cast<size_t>(a.channel)].record);
        played.word(wired.note, a.note);
        played.word(wired.velocity[Wiring::envelope_amp], a.velocity);
        played.word(wired.velocity[Wiring::envelope_mod], 1.0);
        played.dword(wired.level[Wiring::envelope_amp], a.level_amp);
        played.dword(wired.level[Wiring::envelope_mod], a.level_mod);
        // in the decay, whose rate is 0: the levels stand
        for (int e = 0; e < Wiring::envelope_count; ++e) {
            played.stage(wired.stage[static_cast<size_t>(e)],
                         synth.wiring()
                                 .channels[0]
                                 .segments[static_cast<size_t>(e)]
                                          [Wiring::stage_decay]
                                 .record);
        }
    }
    played.send();
    csp::Processor &processor = *played.processor;
    start(processor, played.built->image);

    // The phases take a step a pass, and a write that stops the LFOs reaches
    // the registers after the pass it was sent before: that pass steps too,
    // and so does every pass the writes take to land.
    // The steps run for a few passes, and the writes that stop them take a
    // pass each until they land; a channel's phase is where its steps took it
    for (int n = 0; n < stepping_passes; ++n) {
        pass(processor, "the Noaidi's formulas, stepping");
    }
    for (const Wiring::Lfo &lfo : synth.wiring().lfos) {
        played.dword(lfo.step, 0);
    }
    played.send();
    while (processor.queued_writes() > 0) {
        pass(processor, "the Noaidi's formulas, the last step");
    }
    for (int n = 0; n < 3; ++n) {
        pass(processor, "the Noaidi's formulas, standing");
    }
    // the phases the program holds, and the waves they are: a wave is the
    // shape's formula at the phase the same pass read
    std::array<double, Wiring::lfo_count> phase;
    for (int c = 0; c < SoundEngine::channel_count; ++c) {
        const Wiring::Channel &wired =
                synth.wiring().channels[static_cast<size_t>(c)];
        for (int l = 0; l < Wiring::channel_lfo_count; ++l) {
            const int at = c * Wiring::channel_lfo_count + l;
            phase[static_cast<size_t>(at)] =
                    static_cast<double>(processor.read_wide(played.address(
                            wired.phase[static_cast<size_t>(l)])))
                    / static_cast<double>(int64_t{1}
                                          << csp::wide_fraction_bits);
            lfo_out[static_cast<size_t>(at)] =
                    lfo_wave(shape_of(c, l), phase[static_cast<size_t>(at)]);
        }
    }
    // the phases are inside their cycle, and the steps carried them off zero
    double largest = 0;
    int stepped    = 0;
    for (const double each : phase) {
        largest = std::max(largest, std::fabs(each));
        stepped += std::fabs(each) > 0.1 ? 1 : 0;
    }
    check(largest <= 8.0, "every phase is inside its cycle: the largest is "
                                  + std::to_string(largest));
    check(stepped >= Wiring::lfo_count / 2,
          "the steps carried the phases off zero: " + std::to_string(stepped)
                  + " of " + std::to_string(Wiring::lfo_count));

    double worst_channel = 0;
    for (int c = 0; c < SoundEngine::channel_count; ++c) {
        const Channel &a     = channel[static_cast<size_t>(c)];
        const double lfo1    = lfo_out[static_cast<size_t>(2 * c)];
        const double lfo2    = lfo_out[static_cast<size_t>(2 * c + 1)];
        const double want[3] = {a.duty0 + lfo2, a.duty1 + lfo2,
                                a.resonance + lfo1};
        const int fields[3]  = {Wiring::ChannelSink::duty_0,
                                Wiring::ChannelSink::duty_1,
                                Wiring::ChannelSink::resonance};
        const int sinks =
                Wiring::ChannelSink::base + Wiring::ChannelSink::block * c;
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
    for (int v = 0; v < SoundEngine::voice_count; ++v) {
        const Voice &a    = voice[static_cast<size_t>(v)];
        const Channel &c  = channel[static_cast<size_t>(a.channel)];
        const double lfo1 = lfo_out[static_cast<size_t>(2 * a.channel)];
        const double lfo2 = lfo_out[static_cast<size_t>(2 * a.channel + 1)];
        const double channel_pitch = c.bend + lfo1 * c.p1 + lfo2 * c.p2;
        // the cutoff tracks the bend and the note, not the pitch LFOs: an
        // LFO on the pitch does not sweep the filter too
        const double channel_cutoff =
                c.base + lfo1 * c.c1 + lfo2 * c.c2 + c.track * c.bend;
        const double want[3] = {a.note + channel_pitch,
                                4 * a.level_mod * c.amount + a.note * c.track
                                        + channel_cutoff,
                                a.level_amp * a.velocity};
        const int fields[3]  = {Wiring::VoiceSink::pitch,
                                Wiring::VoiceSink::cutoff,
                                Wiring::VoiceSink::gain};
        const int sinks =
                Wiring::VoiceSink::base + Wiring::VoiceSink::block * v;
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
    const SoundEngine &synth       = *played.synth;
    const Wiring::Channel &channel = synth.wiring().channels[0];
    constexpr int amp              = Wiring::envelope_amp;
    // attack to 1.3 × full, decay to a sustain of 0.5, release to 0
    constexpr std::array<double, Wiring::stage_count> target = {1.3, 0.5, 0.0};
    constexpr std::array<double, Wiring::stage_count> rate = {0.1, 0.05, 0.05};
    for (int e = 0; e < Wiring::envelope_count; ++e) {
        for (int s = 0; s < Wiring::stage_count; ++s) {
            const Wiring::Segment &segment =
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
    for (const Wiring::Voice &voice : synth.wiring().voices) {
        played.pointer(voice.channel, channel.record);
        for (int e = 0; e < Wiring::envelope_count; ++e) {
            played.word(voice.velocity[static_cast<size_t>(e)], 1.0);
            played.stage(voice.stage[static_cast<size_t>(e)],
                         segment_of(e, Wiring::stage_release));
        }
    }
    const Wiring::Voice &struck = synth.wiring().voices[0];
    const Wiring::Voice &idle   = synth.wiring().voices[1];
    played.stage(struck.stage[amp], segment_of(amp, Wiring::stage_attack));
    played.send();
    csp::Processor &processor = *played.processor;
    start(processor, played.built->image);

    const Graph &graph = synth.graph();
    auto offset_of     = [&](int stage) {
        return graph.offset(segment_of(amp, stage));
    };
    auto gain_of = [&](int v) {
        return played.sink(Wiring::VoiceSink::base
                           + Wiring::VoiceSink::block * v
                           + Wiring::VoiceSink::gain);
    };

    // the formula, beside the model
    int stage      = Wiring::stage_attack;
    double level   = 0;
    double worst   = 0;
    double highest = 0;
    auto one_pass  = [&](const std::string &what) {
        pass(processor, what);
        if (level >= 1.0) {
            stage = std::max(stage, static_cast<int>(Wiring::stage_decay));
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
           && stage_word() == offset_of(Wiring::stage_attack)) {
        one_pass("the attack");
        ++passes_to_decay;
    }
    check_equal(stage_word(), offset_of(Wiring::stage_decay),
                "the attack ends in the decay");
    check_equal(stage, Wiring::stage_decay, "in the pass the formula says");
    check(highest >= 1.0, "with the level at full scale");
    check_equal(processor.read(played.address(idle.stage[amp])),
                offset_of(Wiring::stage_release),
                "a voice never struck stays in release");
    check_equal(processor.read_wide(played.address(idle.level[amp])), 0,
                "at zero");

    for (int n = 0; n < 400; ++n) {
        one_pass("the decay");
    }
    check(std::fabs(gain_of(0) - 0.5) < 0.001,
          "the decay settles at the sustain level");

    // struck again while it sounds: the level climbs on from where it is
    played.stage(struck.stage[amp], segment_of(amp, Wiring::stage_attack));
    played.send();
    one_pass("the note on lands");
    stage = Wiring::stage_attack;
    one_pass("struck again");
    check_equal(stage_word(), offset_of(Wiring::stage_attack),
                "a voice struck again is in the attack");
    check(gain_of(0) > 0.5 && gain_of(0) < 1.0,
          "and climbs on from the sustain level: "
                  + std::to_string(gain_of(0)));
    for (int n = 0; n < 100 && stage_word() == offset_of(Wiring::stage_attack);
         ++n) {
        one_pass("the second attack");
    }
    check_equal(stage_word(), offset_of(Wiring::stage_decay),
                "and ends in the decay at full scale");

    // let go: the firmware writes the release, and the program leaves it
    played.stage(struck.stage[amp], segment_of(amp, Wiring::stage_release));
    played.send();
    one_pass("the note off lands");
    stage = Wiring::stage_release;
    for (int n = 0; n < 400; ++n) {
        one_pass("the release");
    }
    check_equal(stage_word(), offset_of(Wiring::stage_release),
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
    test_a_nested_select(2, false, 0); // straight-line code
    test_a_nested_select(8, false, 0); // too few for a round
    test_a_nested_select(16, true, 9); // a loop's body, of sixteen
    test_selects_against_their_own_compares(1, false, 1);
    test_selects_against_their_own_compares(2, false, 1);
    test_selects_against_their_own_compares(2, true, 1);
    test_selects_against_their_own_compares(3, false, 1);
    test_selects_against_their_own_compares(3, true, 1);
    test_selects_against_their_own_compares(3, false, 16); // a loop's body
    test_selects_against_their_own_compares(3, true, 16);
    test_a_constant_is_the_word_it_says();
    test_the_interpreter();
    test_todays_synth();
    test_fewer_paths();
    test_the_noaidis_formulas();
    test_the_noaidis_envelope();
    std::printf("dsp graph: %s (%d checks, %d failures)\n",
                failures ? "FAIL" : "ALL PASS", checks, failures);
    return failures ? 1 : 0;
}
