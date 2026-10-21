//------------------------------------------------------------------------
// lab_pkg.sv — the lab's sizes (#241)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//------------------------------------------------------------------------
package lab_pkg;
    parameter int STIMULUS_W = 96;    // the pattern every device is fed from: two LFSRs side by side
    parameter int COUNTER_W  = 36;    // a counter is one dword of the map
    parameter int DEVICES    = 15;    // devices under test, each a counter; lab.sv instantiates them
endpackage
