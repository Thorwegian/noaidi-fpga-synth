// csp_graph.hpp — the CSP graph: a control program as its block diagram
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A control program described as the textbook block diagram it is: what
// feeds what. The graph is a model of results. It states no width, no
// overflow kind, no scale, no address, no order of a sum's terms and no
// order of statements: how the chip reaches a result is the compiler's.
//
//   component  a relation between its sinks and its source: a sum, a
//              product, a z⁻¹, an accumulator, a one-pole, a comparison, a
//              mux, an absolute value, a minimum, a maximum
//   signal     what joins them: one source, any number of sinks
//   pin        a source or a sink, on a component and on a module alike
//   module     a diagram with named pins, defined once and instanced many
//              times; a module may hold modules
//
// The graph has two ends. The firmware has sources, the values it sets, and
// a partial has sinks, its parameters. Everything between them has both.
// A vibrato, whole:
//
//   Graph graph;
//   const auto lfo = graph.instance<Lfo>("lfo");
//   lfo.firmware_source(&Lfo::step, {0.0f, Lfo::step_at(50.0f)});
//   lfo.firmware_source(&Lfo::shape);
//   const auto note  = graph.firmware_source<Control>("note", {-5, 5});
//   const auto depth = graph.firmware_source<Control>("depth", {0, 2});
//   graph.partial_sink("pitch", {-5, 5}) = note + depth * lfo[&Lfo::wave];
//
// A signal has a unit, and the compiler joins only like to like: a control
// value, a phase, or a select. A signal has a range too, the least and the
// greatest value it can take. The author states a range at a source of the
// firmware and at a sink of a partial, and nowhere else: every other range
// follows from the components. A control value saturates at a partial's
// sink and at a state that is kept, never on the way.
//
// A pin is joined with `=`, as a continuous assignment is in SystemVerilog:
// it states a relation, once, and the order of the statements says nothing.
// The pin on the left is driven by the signal on the right. A signal may be
// on the right of any number of joins, and a pin on the left of one.
//
// The graph has a namespace of its own, csp::graph, apart from the chip's
// in csp: nothing in the model is named for a format or a field of the chip.
//
// Built without exceptions or RTTI, as the firmware is.

#pragma once

#include <concepts>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <type_traits>
#include <vector>

namespace csp::graph {

// ---- units ------------------------------------------------------------------

// A number as the author means it: 1.0 is 1.0, and 32 octaves is 32.
struct Control {};

// A fraction of a cycle. It wraps by definition, so a sum of phases and an
// accumulator of phase wrap without the author saying so.
struct Phase {};

// A type a select can be of: bool, or an enumeration that ends in `count`,
// the enumerator that says how many values come before it.
template <typename Type>
concept Enumerated = std::same_as<Type, bool>
                     || (std::is_enum_v<Type> && requires { Type::count; });

// How many values a select of this type has.
template <Enumerated Type>
inline constexpr std::size_t value_count =
        static_cast<std::size_t>(Type::count);
template <>
inline constexpr std::size_t value_count<bool> = 2;

// One of a named set of values: an enumeration's, or false and true.
template <Enumerated Enumeration>
struct Select {};

// A select of two: what a comparison says, and what gates an envelope.
using Flag = Select<bool>;

template <typename Unit>
concept Quantity = std::same_as<Unit, Control> || std::same_as<Unit, Phase>;

// The least and the greatest value a signal can take.
struct Range {
    float least;
    float greatest;
};

class Module;

// ---- signals ----------------------------------------------------------------

// What one source drives and any number of sinks take in.
template <typename Unit>
class Signal {
public:
    // A constant, written in its unit.
    Signal(float value)
        requires std::same_as<Unit, Control>;

private:
    friend class Module;
    Module *module_ = nullptr; // the diagram the signal is in; none: a constant
    int32_t component_ = -1;   // whose source drives it
    float constant_    = 0.0f;
};

// ---- components -------------------------------------------------------------
//
// Each has one source, which it returns, and the sinks its relation needs.

// A sum: any number of sinks, each with a sign.
Signal<Control> operator+(Signal<Control> a, Signal<Control> b);
Signal<Control> operator-(Signal<Control> a, Signal<Control> b);
Signal<Control> operator-(Signal<Control> a);
Signal<Phase> operator+(Signal<Phase> a, Signal<Phase> b);

// A product. A gain when one of the two is a constant.
Signal<Control> operator*(Signal<Control> a, Signal<Control> b);

Signal<Control> absolute(Signal<Control> a);
Signal<Control> minimum(Signal<Control> a, Signal<Control> b);
Signal<Control> maximum(Signal<Control> a, Signal<Control> b);

// A comparison. Its source is a select source.
Signal<Flag> operator<(Signal<Control> a, Signal<Control> b);
Signal<Flag> operator>(Signal<Control> a, Signal<Control> b);

// A mux: one of its sinks, chosen by its select sink. The sinks are in the
// order of the select's values, false then true or the enumeration's, and
// there is one for each value: any other number does not compile.
template <Enumerated Enumeration, std::size_t Count>
    requires(Count == value_count<Enumeration>)
Signal<Control> mux(Signal<Select<Enumeration>> select,
                    const Signal<Control> (&sinks)[Count]);

// A phase as a control value: −1 … +1 across the cycle, 0 at the phase's
// zero.
Signal<Control> bipolar(Signal<Phase> phase);

// ---- pins -------------------------------------------------------------------
//
// A module's pins are named from outside, as a component's are: the module
// drives its sources and takes signals in at its sinks.

// A pin that takes a signal in. Whoever uses the module joins it; inside
// the module it is the signal that arrives.
template <typename Unit>
class Sink : public Signal<Unit> {
public:
    // Join: this sink takes the signal. A sink takes one.
    Sink &operator=(Signal<Unit> signal);
    Sink &operator=(const Sink &arriving);
    Sink(const Sink &) = default;

private:
    friend class Module;
    Sink() = default;
};

// A pin the module drives. The module joins it; whoever uses the module
// reads it as the signal it drives.
template <typename Unit>
class Source : public Signal<Unit> {
public:
    // Join: this source drives the signal. A source drives one.
    Source &operator=(Signal<Unit> signal);
    Source &operator=(const Source &driving);
    Source(const Source &) = default;

private:
    friend class Module;
    Source() = default;
};

// A z⁻¹: its source is last pass's value at its sink. A pass is 1/24 000 s.
// The sink may be joined after the source is read, which is how a loop is
// closed.
template <typename Unit>
struct UnitDelay {
    Sink<Unit> sink;
    Source<Unit> source;
};

// ---- modules ----------------------------------------------------------------

template <typename Definition>
class Instance;

// A diagram with named pins. A module is a struct that derives from this:
// its pins are its members, and its constructor states the diagram. The
// graph constructs it once, however many instances there are, and an
// instance holds its joins and its own state, not a copy of the diagram.
class Module {
protected:
    Module();

    // A pin, by the name it has in the tree.
    template <typename Unit>
    Sink<Unit> sink(std::string_view name);
    template <typename Unit>
    Source<Unit> source(std::string_view name);

    // The components that keep a value from one pass to the next. Every
    // state has a name, so every state of every instance can be found.

    // y[n] = y[n−1] + x[n]
    Signal<Phase> accumulator(std::string_view name, Signal<Phase> step);
    // y[n] = y[n−1] + r·(target − y[n−1])
    Signal<Control> one_pole(std::string_view name, Signal<Control> target,
                             Signal<Control> rate);
    template <typename Unit>
    UnitDelay<Unit> unit_delay(std::string_view name);

public:
    // An instance of a module inside this one: `name`, or `name[index]`.
    template <std::derived_from<Module> Definition>
    Instance<Definition> instance(std::string_view name);
    template <std::derived_from<Module> Definition>
    Instance<Definition> instance(std::string_view name, int index);
};

// One use of a module. Its pins are reached through the definition's
// members: `lfo[&Lfo::step] = signal` joins a sink, and `lfo[&Lfo::wave]`
// is the signal a source drives.
template <typename Definition>
class Instance {
public:
    template <typename Unit>
    Sink<Unit> operator[](Sink<Unit> Definition::*pin) const;
    template <typename Unit>
    Signal<Unit> operator[](Source<Unit> Definition::*pin) const;

    // The firmware drives this sink: a source of the firmware, named for
    // the pin, joined to it.
    template <Quantity Unit>
    Source<Unit> firmware_source(Sink<Unit> Definition::*pin,
                                 Range range) const;
    template <Enumerated Enumeration>
    Source<Select<Enumeration>>
    firmware_source(Sink<Select<Enumeration>> Definition::*pin) const;

private:
    friend class Module;
    Module *owner_ = nullptr; // the module the instance is in
    int32_t index_ = -1;      // which of its instances
};

// ---- the graph --------------------------------------------------------------

// The whole tree: the outermost diagram, with the two ends.
class Graph : public Module {
public:
    Graph();

    // A source of the firmware: a value it sets, in its unit. A value set
    // outside the range is clamped here.
    template <Quantity Unit>
    Source<Unit> firmware_source(std::string_view name, Range range);
    // A select the firmware writes.
    template <Enumerated Enumeration>
    Source<Select<Enumeration>> firmware_source(std::string_view name);

    // A sink of a partial: one of its parameters. A control value
    // saturates here, at the range the partial takes.
    Sink<Control> partial_sink(std::string_view name, Range range);

    // What the graph refuses, each by the name of the pin or the state: a
    // pin joined twice, a pin left unjoined, a loop whose range does not
    // close.
    struct Issue {
        std::string message;
    };
    const std::vector<Issue> &issues() const;
};

} // namespace csp::graph
