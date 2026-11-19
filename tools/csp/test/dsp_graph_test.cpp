// dsp_graph_test.cpp — host tests for the DSP graph (app/main/csp/dsp_graph.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Two things. Each operator and each kind of connection in a small graph,
// its image run on the reference model and every value checked. And the
// Noaidi's wiring (app/main/wiring.cpp: 8 LFOs, 16 channels, 32 voices, the
// copies made by loops), its image run on the reference model beside today's
// control program (app/main/csp/generator.cpp) on the same notes and
// controller values, wires moved while it plays: every sink holds the same
// value, pass for pass, and the model reports no read before ready. The test
// prints the image's rows and the pass's cycles.
//
//   make csp-test

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "../performance.hpp"
#include "../processor.hpp"
#include "csp/control_program.hpp"
#include "csp/dsp_graph.hpp"
#include "csp/generator.hpp"
#include "graph_evaluator.hpp"
#include "wiring.hpp"

namespace {

namespace cp = csp::control;

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
    processor.write(graph.address(a), q(0.5));
    processor.write(graph.address(b), q(0.25));
    processor.write(graph.address(c), q(2.0));
    processor.write(graph.address(large), q(6.0));
    processor.write(graph.address(larger), q(5.0));
    processor.write_wide(graph.address(step), q_wide(0.75));
    for (int t = 0; t < 3; ++t) {
        processor.write(graph.address(targets[t].gain), q(0.5 * (t + 1)));
        processor.write(graph.address(targets[t].low), q(-1.0 - t));
        processor.write(graph.address(targets[t].high), q(1.0 + t));
    }
    processor.write(graph.address(pointer), graph.address(targets[0].record));
    processor.write(graph.address(which), graph.offset(targets[0].lows));
    start(processor, built.image);

    pass(processor, "the small graph");
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

    pass(processor, "the small graph");
    pass(processor, "the small graph");
    check_equal(processor.sink(was), q(0.5),
                "a delay's output is its input's value of the pass before");
    check_equal(processor.sink(counted), q(0.75),
                "a sum onto its own delayed output counts");
    check_equal(processor.read_wide(graph.address(totalling)), q_wide(1.125),
                "a dword multiply-add onto its own delayed output");
    check_equal(processor.sink(totalled), q(1.125),
                "an operator of words reads a dword's upper word");

    // the wire moved: one write of the pointer, one of the offset
    processor.write(graph.address(pointer), graph.address(targets[2].record));
    processor.write(graph.address(which), graph.offset(targets[2].highs));
    processor.swap();
    pass(processor, "the small graph");
    pass(processor, "the small graph");
    check_equal(processor.sink(pointed), q(0.75),
                "the pointer moved, the field follows");
    check_equal(processor.sink(inside), q(3.5),
                "the offset moved, the record inside follows");
    check_equal(processor.sink(straight), q(1.5), "and the sink's");
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
    start(processor, built.image);
    pass(processor, "the field summed onto");
    check_equal(processor.sink(0), q(1.25), "a sum onto a record's field");
    check_equal(processor.sink(1), q(0.75),
                "the field through a pointer, a sum onto it made");
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
    auto point     = [&](int moved) {
        for (int c = 0; c < count; ++c) {
            const Copy &copy = copies[static_cast<size_t>(c)];
            processor->write(graph.address(copy.target),
                                 graph.address(targets[(c + moved) % 3].record));
            processor->write(graph.address(copy.scaler),
                                 graph.address(scalers[(c + moved) % 2].record));
        }
    };
    for (int t = 0; t < 3; ++t) {
        processor->write(graph.address(targets[t].gain), q(gains[t]));
        processor->write(graph.address(targets[t].level), q(levels[t]));
    }
    for (int s = 0; s < 2; ++s) {
        processor->write(graph.address(scalers[s].scale), q(scales[s]));
    }
    processor->write(graph.address(master), q(shared));
    for (int c = 0; c < count; ++c) {
        processor->write(graph.address(copies[static_cast<size_t>(c)].a),
                         q(a_of(c)));
        processor->write(graph.address(copies[static_cast<size_t>(c)].b),
                         q(b_of(c)));
    }
    for (const Graph::InitialValue &initial : graph.initial_values()) {
        processor->write(initial.address, initial.value);
    }
    point(0);
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
    }
    check_equal(expect(0), 0, what + ": sinks that are wrong");
    point(1); // every wire moved
    processor->swap();
    do { // the firmware's writes land a queue's share a pass
        pass(*processor, what);
        ++passes;
    } while (processor->queued_writes() > 0);
    for (int settled = 0; settled < 2; ++settled, ++passes) {
        pass(*processor, what);
    }
    check_equal(expect(1), 0, what + ": sinks that are wrong, the wires moved");
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
    for (int c = 0; c < count; ++c) {
        processor->write(graph.address(counters[c].a), q(a_of(c)));
        processor->write(graph.address(counters[c].other),
                         graph.address(counters[(c + 5) % count].record));
    }
    start(*processor, built.image);
    constexpr int passes = 3;
    for (int at = 0; at < passes; ++at) {
        pass(*processor, "copies that point at each other");
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

// ---- the Noaidi's wiring -------------------------------------------------------------
//
// The synth the firmware wires (app/main/wiring.cpp): what generator.cpp's
// program computes, as sources, operators and sinks.

using wiring::channel_count;
using wiring::envelope_count;
using wiring::lfo_count;
using wiring::moved_count;
using wiring::stage_count;
using wiring::voice_count;

using Synth   = wiring::Synth;
using Lfo     = wiring::Lfo;
using Segment = wiring::Segment;
using Channel = wiring::Channel;
using Voice   = wiring::Voice;

// ---- both programs on the model ------------------------------------------------------

// Today's program and the graph's, each on a processor of its own, set by
// one hand: every value goes to its word in today's map and to the word the
// graph says.
struct Rig {
    Synth synth;
    csp::Processor today, graphed;

    int address(Wire wire) const {
        return synth.graph.address(wire);
    }
    void word(int today_address, Wire wire, int32_t raw) {
        today.write(today_address, raw);
        graphed.write(address(wire), raw);
    }
    void dword(int today_address, Wire wire, int64_t raw) {
        today.write_wide(today_address, raw);
        graphed.write_wide(address(wire), raw);
    }
    void swap() {
        today.swap();
        graphed.swap();
    }

    static int today_lfo(int l) {
        return cp::lfos + ((l / 4) * cp::lfos_a_half + l % 4) * cp::lfo_size;
    }
    static int today_channel(int c) {
        return cp::channels + c * cp::channel_size;
    }
    static int today_voice(int v) {
        return cp::voices + v * cp::voice_size;
    }

    // the movable wires
    void voice_channel(int v, int c) {
        today.write(today_voice(v) + cp::channel, today_channel(c));
        graphed.write(address(synth.voices[v].channel),
                      synth.graph.address(synth.channels[c].record));
    }
    void channel_lfo(int c, int which, int l) {
        today.write(today_channel(c) + cp::lfo1 + which, today_lfo(l));
        graphed.write(address(synth.channels[c].lfo[which]),
                      synth.graph.address(synth.lfos[l].record));
    }
    // a note on (stage 0) or off (stage 2) for both envelopes
    void voice_stage(int v, int stage) {
        const int today_stage[envelope_count] = {cp::stage_a, cp::stage_m};
        for (int e = 0; e < envelope_count; ++e) {
            today.write(today_voice(v) + today_stage[e],
                        (e * 4 + stage) * cp::segment_size);
            graphed.write(address(synth.voices[v].stage[e]),
                          synth.graph.offset(
                                  synth.channels[0].segments[e][stage].record));
        }
    }

    void set_up() {
        for (int half = 0; half < 2; ++half) {
            today.write(cp::lfo_sets + half * cp::set_size + cp::base,
                        cp::lfos + half * cp::lfos_a_half * cp::lfo_size);
        }
        for (int l = 0; l < lfo_count; ++l) {
            const double depth = 0.3 + 0.05 * l;
            const int at       = today_lfo(l);
            const Lfo &lfo     = synth.lfos[l];
            dword(at + cp::phase_step, lfo.step,
                  q_wide(0.0031 * (l + 1) * 16.0));
            word(at + cp::depth, lfo.depth, q(depth));
            word(at + cp::neg_depth, lfo.neg_depth, q(-depth));
            word(at + cp::gain, lfo.gain,
                 q(l % 4 == 2 ? depth / 4 : depth / 8));
        }
        for (int c = 0; c < channel_count; ++c) {
            const int at           = today_channel(c);
            const Channel &channel = synth.channels[c];
            word(at + cp::bend, channel.bend, q(0.02 * (c - 8)));
            const int today_depth[2][moved_count] = {
                    {cp::lfo1_pitch, cp::lfo1_cutoff, cp::lfo1_duty,
                     cp::lfo1_resonance},
                    {cp::lfo2_pitch, cp::lfo2_cutoff, cp::lfo2_duty,
                     cp::lfo2_resonance}};
            for (int l = 0; l < 2; ++l) {
                for (int k = 0; k < moved_count; ++k) {
                    word(at + today_depth[l][k], channel.depth[l][k],
                         q(0.05 * ((c + 3 * l + k) % 7) - 0.1));
                }
                channel_lfo(c, l, (3 * c + 5 * l + 1) % lfo_count);
            }
            word(at + cp::cutoff_base, channel.cutoff_base,
                 q(0.5 + 0.1 * (c % 5)));
            word(at + cp::key_track, channel.key_track, q(0.25 * (c % 5)));
            word(at + cp::mod_amount, channel.mod_amount, q(0.1 + 0.03 * c));
            word(at + cp::duty_base_0, channel.duty_base[0], q(0.1 + 0.02 * c));
            word(at + cp::duty_base_1, channel.duty_base[1],
                 q(-0.3 + 0.03 * c));
            word(at + cp::resonance_base, channel.resonance_base,
                 q(0.5 + 0.1 * (c % 7)));
            today.write(at + cp::sink_block,
                        cp::channel_sinks + c * cp::channel_sink_size);
            const double targets[envelope_count][stage_count] = {
                    {1.25, 0.4 + 0.02 * c, 0.0}, {1.25, 0.2 + 0.03 * c, 0.0}};
            const double rates[envelope_count][stage_count] = {
                    {0.02 + 0.004 * c, 0.004, 0.008},
                    {0.05, 0.002 + 0.001 * c, 0.02}};
            for (int e = 0; e < envelope_count; ++e) {
                for (int s = 0; s < stage_count; ++s) {
                    const int row =
                            at + cp::envelopes + (e * 4 + s) * cp::segment_size;
                    const Segment &segment = channel.segments[e][s];
                    dword(row + cp::target, segment.target,
                          q_wide(targets[e][s]));
                    dword(row + cp::rate, segment.rate, q_wide(rates[e][s]));
                }
            }
        }
        for (int v = 0; v < voice_count; ++v) {
            const int at       = today_voice(v);
            const Voice &voice = synth.voices[v];
            word(at + cp::note, voice.note, q(-1.0 + 0.1 * v));
            word(at + cp::velocity, voice.velocity[0], q(0.3 + 0.02 * v));
            word(at + cp::velocity_m, voice.velocity[1], q(1.0 - 0.01 * v));
            today.write(at + cp::sink, cp::sinks + v * cp::voice_sinks_size);
            voice_channel(v, (5 * v + 1) % channel_count);
            voice_stage(v, v % 3 == 0 ? 2 : 0); // idle, or in its attack
        }
    }
};

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
    csp::ProgramBuilder::Built today;
    csp::generate(csp::control_graph(), today);
    check(today.ok, "today's control program builds");

    auto rig = std::make_unique<Rig>();
    wiring::wire(rig->synth);
    csp::ProgramBuilder::Built graphed;
    const auto began = std::chrono::steady_clock::now();
    const bool built =
            build(rig->synth.graph, graphed, "today's synth as a graph");
    const auto took = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - began);
    if (!built) {
        return;
    }
    int direct = 0, upper = 0;
    for (int address = 0; address < csp::register_count; ++address) {
        if (rig->synth.graph.writer(address) != Graph::Writer::nobody) {
            ++(address < csp::direct_reach ? direct : upper);
        }
    }
    std::printf(
            "today's control program (vector loops): %d rows, %d decode rows, %d cycles a pass\n",
            today.image.length, today.image.rom_used, today.cycles);
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

    Graph &graph = rig->synth.graph;
    check(graph.writer(graph.address(rig->synth.voices[5].note))
                  == Graph::Writer::firmware,
          "a voice's note is the firmware's word");
    check(graph.writer(graph.address(rig->synth.voices[5].stage[1]))
                  == Graph::Writer::program,
          "a voice's stage is a word the program writes");
    check(graph.address(rig->synth.channels[3].record) % 32 == 0,
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
    check(graphed.cycles < today.cycles
                  && graphed.image.length < today.image.length,
          "the graph's program is shorter than today's, in rows and in cycles");
    check_equal(
            static_cast<int64_t>(graph.initial_values().size()),
            channel_count + voice_count,
            "words the graph has the firmware set at load: a pointer to its sinks for each element");
    check(graph.writer(graph.initial_values().front().address)
                  == Graph::Writer::firmware,
          "such a word is the firmware's");

    rig->set_up();
    for (const Graph::InitialValue &initial : graph.initial_values()) {
        rig->graphed.write(initial.address, initial.value);
    }
    start(rig->today, today.image);
    start(rig->graphed, graphed.image);

    // the interpreter, set by the performance the Rig plays
    auto evaluator = std::make_unique<csp::GraphEvaluator>(graph);
    for (const performance::Setting &setting :
         performance::set_up(rig->synth)) {
        set(*evaluator, setting);
    }

    int differences = 0, interpreted = 0, early = 0, stale = 0, cycles = 0,
        todays_errors = 0;
    const int passes  = 600;
    for (int at = 1; at <= passes; ++at) {
        // the performance: wires moved and notes played while it runs
        const performance::Settings changes =
                performance::before_pass(rig->synth, at);
        if (at == 120) {
            for (int v = 0; v < voice_count; v += 2) {
                rig->voice_channel(v, (7 * v + 3) % channel_count);
            }
            rig->swap();
        }
        if (at == 200) {
            for (int v = 1; v < voice_count; v += 2) {
                rig->voice_stage(v, 2); // note off
            }
            rig->swap();
        }
        if (at == 300) {
            for (int c = 0; c < channel_count; ++c) {
                rig->channel_lfo(c, c % 2, (c + 2) % lfo_count);
            }
            rig->swap();
        }
        if (at == 380) {
            for (int v = 0; v < voice_count; v += 3) {
                rig->voice_stage(v, 0); // note on
            }
            rig->swap();
        }
        todays_errors += static_cast<int>(rig->today.pass().errors.size());
        const csp::PassReport report = rig->graphed.pass();
        for (const std::string &error : report.errors) {
            if (early++ < 3) {
                std::printf("  pass %d: %s\n", at, error.c_str());
            }
        }
        stale += static_cast<int>(report.stale_sinks.size());
        cycles = std::max(cycles, report.cycles);
        evaluator->pass();
        // the firmware's writes land in the model at the end of this pass:
        // the interpreter takes them for the pass after, as the model does
        if (report.writes_applied > 0) {
            for (const performance::Setting &setting : changes) {
                set(*evaluator, setting);
            }
        }
        auto compare = [&](int address, const char *what, int index, int k) {
            const int offset   = address - csp::sink_base;
            const int32_t want = rig->today.sink(offset);
            const int32_t got  = rig->graphed.sink(offset);
            if (want != got && differences++ < 5) {
                std::printf(
                        "  pass %d, %s %d sink %d: %d, today's program has %d\n",
                        at, what, index, k, got, want);
            }
        };
        for (int v = 0; v < voice_count; ++v) {
            for (const int k :
                 {cp::sink_pitch, cp::sink_cutoff, cp::sink_gain}) {
                compare(cp::sinks + v * cp::voice_sinks_size + k, "voice", v,
                        k);
            }
        }
        for (int c = 0; c < channel_count; ++c) {
            for (const int k : {cp::duty_0, cp::duty_1, cp::resonance}) {
                compare(cp::channel_sinks + c * cp::channel_sink_size + k,
                        "channel", c, k);
            }
        }
        // the interpreter's sinks, every one the graph has
        for (const int address : evaluator->sink_addresses()) {
            const int32_t from_program =
                    rig->graphed.sink(address - csp::sink_base);
            const int32_t from_graph = evaluator->sink(address);
            if (from_program != from_graph && interpreted++ < 5) {
                std::printf(
                        "  pass %d, sink 0x%03x: the interpreter has %d, the "
                        "graph's program %d\n",
                        at, address, from_graph, from_program);
            }
        }
    }
    check_equal(differences, 0,
                "sinks that differ from today's program over "
                        + std::to_string(passes) + " passes");
    check_equal(interpreted, 0,
                "sinks where the interpreter and the graph's program differ "
                "over " + std::to_string(passes)
                        + " passes");
    check_equal(todays_errors, 0,
                "complaints of the model about today's program");
    check_equal(early, 0, "reads before ready reported by the model");
    check_equal(stale, 0, "sinks the graph's program left unwritten");
    check_equal(cycles, graphed.cycles,
                "the model runs the cycles the builder counted");

    // that the comparison is of live values: sinks move, and differ by voice
    const int32_t gain_1 =
            rig->graphed.sink(cp::sinks - csp::sink_base
                              + 1 * cp::voice_sinks_size + cp::sink_gain);
    const int32_t gain_2 =
            rig->graphed.sink(cp::sinks - csp::sink_base
                              + 2 * cp::voice_sinks_size + cp::sink_gain);
    check(gain_1 != 0 && gain_2 != 0 && gain_1 != gain_2,
          "the voices' gains are alive at the end");
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
    test_todays_synth();
    std::printf("dsp graph: %s (%d checks, %d failures)\n",
                failures ? "FAIL" : "ALL PASS", checks, failures);
    return failures ? 1 : 0;
}
