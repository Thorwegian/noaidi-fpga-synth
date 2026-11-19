// generator.hpp — the control program, generated from the control graph
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The firmware's code generator: it walks a control graph (graph.hpp) and
// emits the program through csp::ProgramBuilder, one emitter for each kind
// of node, in the order the values depend on each other: the LFOs, the
// channels, the envelopes, the voices. The builder schedules, counts the
// pass's cycles and encodes into `built`, which the caller keeps: the image
// the engine link loads, and the issues of a graph whose program does not
// fit a pass.
//
// The registers the program works on are those of the control program's map
// (tools/csp/programs/map.s), by the names of control_program.hpp.
//
// Built without exceptions or RTTI, as the firmware is.

#pragma once

#include "graph.hpp"
#include "program_builder.hpp"

namespace csp {

void generate(const Graph &graph, ProgramBuilder::Built &built);

// The graph the firmware runs: every channel and voice the map holds, and
// the LFOs of tools/csp/programs/counts.s.
Graph control_graph();

} // namespace csp
