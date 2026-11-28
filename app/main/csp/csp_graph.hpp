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
// The graph has two ends, and each is a module of its own, though its
// inside is not in the graph: the firmware, whose pins are sources, the
// values it sets, and a partial, whose pins are sinks, its parameters.
// Everything between them has both.
//
// What has a name in the tree is declared with that name: a pin, a
// component that keeps a state, a module. Arithmetic is written as
// arithmetic. Then the joins are stated. A vibrato, whole:
//
//   struct Firmware : External {
//       Source<Control> note{"note", {-5.0f, 5.0f}};
//       Source<Control> depth{"depth", {0.0f, 2.0f}};
//       Source<Phase> rate{"rate", {0.0f, Lfo::step_at(50.0f)}};
//       Source<Select<Lfo::Shape>> shape{"shape"};
//       using External::External;
//   };
//
//   struct Partial : External {
//       Sink<Control> pitch{"pitch", {-5.0f, 5.0f}};
//       using External::External;
//   };
//
//   struct Vibrato : Module {
//       Firmware firmware{"firmware"};
//       Lfo lfo{"lfo"};
//       Partial partial{"partial"};
//
//       explicit Vibrato(Name name) : Module(name) {
//           lfo.step <<= firmware.rate;
//           lfo.shape <<= firmware.shape;
//           partial.pitch <<= firmware.note + firmware.depth * lfo.wave;
//       }
//   };
//
//   const Vibrato vibrato{"vibrato"};
//   const Graph graph{vibrato};
//
// A join is written `<<=`, read as an arrow: what is on the left is driven
// by the signal on the right. A join states a relation, once, as a
// continuous assignment does in SystemVerilog, and the order of the
// statements says nothing. A signal may be on the right of any number of
// joins, and a sink on the left of one. The operator has assignment's
// precedence, so all of the right-hand side is the signal. `=` keeps its
// C++ meaning: it names a signal, and it does not compile on what is
// declared.
//
// A signal has a unit, and the compiler joins only like to like: a control
// value, a phase, or a select. A signal has a range too, the least and the
// greatest value it can take. The author states a range at the two ends, on
// a pin of the firmware and on a pin of a partial, and nowhere else: every
// other range follows from the components. A control value saturates at a
// partial's sink and at a state that is kept, never on the way.
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

protected:
    Signal() = default;

private:
    Module *module_ = nullptr; // the diagram the signal is in; none: a constant
    int32_t component_ = -1;   // whose source drives it
    float constant_    = 0.0f;
};

// ---- arithmetic -------------------------------------------------------------
//
// The components that keep nothing. Each is written as the arithmetic it
// is: its arguments are its sinks, and what it returns is its source.

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

// ---- what is declared -------------------------------------------------------

// A name in the tree: `lfo`, or `lfo[1]` for one of several.
struct Name {
    Name(const char *name);
    Name(std::string_view name, int index);
};

// What has a name in the tree: a pin, a component that keeps a state, a
// module. It belongs to the module whose constructor is running when it is
// declared, and one declared in no module is an outermost one. A copy of it
// is the same thing again, not another one.
class Named {
protected:
    explicit Named(Name name);
    Named(const Named &)            = default;
    Named &operator=(const Named &) = delete;
};

// ---- pins -------------------------------------------------------------------
//
// A module's pins are named from outside, as a component's are: the module
// drives its sources and takes signals in at its sinks.

// A pin that takes a signal in. Whoever uses the module joins it; inside
// the module it reads as the signal that arrives.
template <typename Unit>
class Sink : public Signal<Unit>, public Named {
public:
    explicit Sink(Name name);
    // A sink of an end, with the range it takes: a control value saturates
    // at it.
    Sink(Name name, Range range)
        requires Quantity<Unit>;

    // Join: this sink takes the signal. A sink takes one.
    void operator<<=(Signal<Unit> signal);
};

// A pin the module drives. The module joins it; whoever uses the module
// reads it as the signal it drives.
template <typename Unit>
class Source : public Signal<Unit>, public Named {
public:
    explicit Source(Name name);
    // A source of an end, with its range: a value set outside it is clamped
    // here.
    Source(Name name, Range range)
        requires Quantity<Unit>;

    // Join: this source drives the signal. A source drives one.
    void operator<<=(Signal<Unit> signal);
};

// ---- components that keep a state -------------------------------------------
//
// Each reads as its source. One with a single sink is joined itself, and
// one with several is joined at each sink by its name. Every state has a
// name, so every state of every instance can be found.

// A z⁻¹: its source is last pass's value at its sink. A pass is 1/24 000 s.
// It may be joined after it is read, which is how a loop is closed.
template <typename Unit>
class UnitDelay : public Signal<Unit>, public Named {
public:
    explicit UnitDelay(Name name);

    void operator<<=(Signal<Unit> input);
};

// An accumulator: y[n] = y[n−1] + x[n]. Its sink is x.
template <Quantity Unit>
class Accumulator : public Signal<Unit>, public Named {
public:
    explicit Accumulator(Name name);

    void operator<<=(Signal<Unit> step);
};

// A one-pole: y[n] = y[n−1] + rate·(target − y[n−1]).
class OnePole : public Signal<Control>, public Named {
public:
    explicit OnePole(Name name);

    Sink<Control> target;
    Sink<Control> rate;
};

// ---- modules ----------------------------------------------------------------

// A diagram with named pins. A module is a struct that derives from this:
// what it declares, as its members and in its constructor, is the diagram,
// and declaring one of it is an instance: `Lfo lfo{"lfo"};`, with its pins
// as its members, `lfo.step` and `lfo.wave`.
//
// A module is defined once. The first of a type that is declared states
// the diagram. Each later one states the same diagram, so it adds only
// what is its own: its name, its joins and its states.
class Module : public Named {
public:
    explicit Module(Name name);
};

// A module whose inside is not in the graph: an end. The firmware is one,
// and its sources are the values it sets. A partial is one, and its sinks
// are the parameters it reads. A quantity's pin states its range here.
class External : public Module {
public:
    explicit External(Name name);
};

// ---- the graph --------------------------------------------------------------

// The whole tree, from an outermost module down.
class Graph {
public:
    explicit Graph(const Module &outermost);

    // What the graph refuses, each by its name in the tree: a sink or a
    // source joined twice or left unjoined, a range stated anywhere but at
    // an end, a loop whose range does not close.
    struct Issue {
        std::string message;
    };
    const std::vector<Issue> &issues() const;
};

} // namespace csp::graph
