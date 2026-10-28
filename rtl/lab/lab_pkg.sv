//------------------------------------------------------------------------
// lab_pkg.sv — the lab's sizes (#241)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//------------------------------------------------------------------------
package lab_pkg;
    parameter int STIMULUS_W = 96;    // the pattern every device is fed from: two LFSRs side by side
    parameter int COUNTER_W  = 36;    // a counter is one dword of the map
    // devices under test, each a counter; lab.sv instantiates them. The chains, the shadow-SRAM
    // pair (#309) and the five pin-distance devices (#319) fit beside the CSP; the block and fan-out devices (their references are thousands
    // of flip-flops) are a build of their own: `make pack.fs LAB_BUILD=1 LAB_BLOCKS=1`. The bench
    // runs all of them.
`ifdef LAB_BLOCKS
    parameter int DEVICES    = 22;
`else
    parameter int DEVICES    = 15;
`endif
endpackage
