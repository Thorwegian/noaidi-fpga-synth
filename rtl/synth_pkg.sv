// synth_pkg.sv — shared design parameters
//
// The single home for the design's constants (Thor: modules should
// not carry hardcoded numbers). Modules import what they need; module
// parameters default from here so testbenches can still override.

package synth_pkg;

    parameter int SAMPLE_RATE = 96000;
    // 768 x 96 kHz. Stepped down from 98.304 MHz (1024 slots) after
    // five ear-verified silicon timing failures that STA passed: the
    // fabric has no margin for our 36x36 DSP cascades at ~100 MHz,
    // and 25% more slack protects the paths we haven't found yet.
    parameter int SYS_CLK_HZ  = 73_728_000;

    //--- Drum (SCMO) scheduling -------------------------------------
    parameter int DRUM_CYCLES  = 768;    // SYS_CLK_HZ / SAMPLE_RATE
    parameter int DRUM_W       = 10;     // $clog2(DRUM_CYCLES)
    parameter int CELL_DIV     = 6;      // SPDIF cell = 6 sysclk (768 = 128 x 6)

    //--- Elements and lanes (design doc terminology) ----------------
    // The FPGA generates ELEMENTS (256 of them), technically via
    // LANES — time-multiplexed passes through the pipeline. The
    // ESP32 groups elements into voices; the FPGA never sees that.
    parameter int NUM_ELEMENTS = 256;
    parameter int ELEM_W       = 8;      // $clog2(NUM_ELEMENTS)
    parameter int UNISON       = 8;      // firmware convention only
    parameter int POLYPHONY    = 32;     // firmware convention only

    // Drum slot where element 0 enters the pipeline
    parameter int LANE_BASE    = 0;
    // Pipeline stages per element (S0..S11 + S3B/S5B/S8B/S9B splits)
    parameter int LANE_STAGES  = 16;
    // Contiguous drum span occupied by the lane pipeline
    parameter int LANE_SPAN    = NUM_ELEMENTS + LANE_STAGES - 1;

    // Drum slot where a pending ping-pong bank swap executes: the
    // pipeline is drained there (LANE_SPAN < SWAP_SLOT), so every
    // sample reads one consistent bank generation.
    parameter int SWAP_SLOT    = 512;

    //--- SPI memory map (docs/memory_map.md) ------------------------
    parameter int          MAP_AW_BACKED   = 11;       // 2048-word window
    parameter logic [7:0]  SPI_ID_BYTE     = 8'hA5;
    parameter logic [15:0] MAP_CTRL_ADDR   = 16'h0002; // bit 0: swap request
    parameter logic [15:0] MAP_ELEM_BASE   = 16'h2000; // per-element params
    parameter int          MAP_ELEM_STRIDE = 64;       // words per element

    //--- Bus fabric (docs/bus_architecture.md) ----------------------
    parameter logic [15:0] MAP_BUS_BASE = 16'h0800;    // bus base registers
    parameter int          NUM_BUSES    = 1024;        // uniform pool
    parameter int          BUS_W        = 18;          // signed Q8.10

    //--- Filter stability ceiling (Thor, 2026-08-31) -----------------
    // SVF stability criterion: sin(pi*fc/fs) < Q. Q below ~0.5 never
    // occurs musically, so the binding case is Q = 0.5 -> fc < fs/6
    // = 16 kHz at 96 kHz. Clamp effective cutoff just below that:
    // UQ4.10 with 440 Hz = 0x1700, so 0x2B80 = 440 * 2^5.125
    // = 15.36 kHz. Applied to the effective (base + bus) cutoff in
    // the pipeline — no programmable input can destabilize the filter.
    parameter logic [13:0] FC_MAX = 14'h2B80;

    //--- Number formats (design doc) ---------------------------------
    parameter int OSC_W = 24;       // UQ0.24 phase accumulator
    typedef logic signed [OSC_W-1:0] osc_t;

    parameter int CTRL_W = 14;      // UQ4.10 pitch/cutoff

    parameter int AUDIO_W = 18;     // Q2.16 audio transport
    typedef logic signed [AUDIO_W-1:0] sample_t;

    parameter int SVF_W = 36;       // Q8.28 filter states

    parameter int AUDIO_SHIFT = 14;

endpackage
