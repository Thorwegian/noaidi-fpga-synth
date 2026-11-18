// generator.hpp — the control program, generated from the control graph
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The firmware's code generator: it walks a control graph (graph.hpp) and
// emits the program through csp::ProgramBuilder, one emitter for each kind
// of node, in the order the values depend on each other: the LFOs, the
// channels, the envelopes, the voices. The builder schedules, counts the
// pass's cycles and encodes; what comes back is its result, the image
// the engine link loads and the issues of a graph whose program does not
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

ProgramBuilder::Built generate(const Graph &graph);

} // namespace csp
