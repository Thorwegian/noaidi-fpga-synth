// lfo.hpp — the LFO: a CSP module
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A low-frequency oscillator as its block diagram: an accumulator of phase,
// the four waves read off that phase, and a mux on the shape.
//
//                                       ┌─► saw ──────┐
//   step ──► accumulator ──► bipolar ──┼─► square ───┤
//                                       ├─► triangle ─┼─► mux ──► wave
//                                       └─► sine ─────┘    ▲
//   shape ─────────────────────────────────────────────────┘

#pragma once

#include "../csp.hpp"
#include "../csp_graph.hpp"

namespace csp::graph {

struct Lfo : Module {
    enum class Shape { saw, square, triangle, sine };

    // The phase added each pass, a fraction of a cycle.
    Sink<Phase> step          = sink<Phase>("step");
    Sink<Select<Shape>> shape = sink<Select<Shape>>("shape");
    // −1 … +1
    Source<Control> wave = source<Control>("wave");

    // The step of an LFO at this many cycles a second.
    static constexpr float step_at(float hertz) {
        return hertz / static_cast<float>(pass_rate);
    }

    Lfo() {
        const Signal<Phase> phase = accumulator("phase", step);

        const Signal<Control> saw      = bipolar(phase);
        const Signal<Control> square   = mux(saw < 0.0f, {1.0f, -1.0f});
        const Signal<Control> triangle = 2.0f * absolute(saw) - 1.0f;

        // A sine as a parabola through its zeros and its peaks, corrected
        // by a share of its own square.
        constexpr float correction = 0.225f;
        const Signal<Control> parabola =
                4.0f * saw - 4.0f * absolute(saw) * saw;
        const Signal<Control> sine =
                (1.0f - correction) * parabola
                + correction * parabola * absolute(parabola);

        wave = mux(shape, {saw, square, triangle, sine});
    }
};

} // namespace csp::graph
