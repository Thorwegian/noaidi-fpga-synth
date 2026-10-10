// synth_pkg.sv — shared design parameters
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The single home for the design's constants; no module carries
// hardcoded numbers. Modules import what they need, and module
// parameters default from here so testbenches can still override.

package synth_pkg;

    parameter int SAMPLE_RATE = 96000;
    // 768 x 96 kHz. Not ~100 MHz: at that clock the 36x36 DSP cascades
    // fail on silicon although STA passes, and the extra slack protects
    // paths that STA does not flag.
    parameter int SYS_CLK_HZ  = 73_728_000;

    //--- Timebase (TDM) scheduling ---------------------------------
    parameter int CYCLES_PER_SAMPLE  = 768;    // SYS_CLK_HZ / SAMPLE_RATE
    parameter int TIMEBASE_W       = 10;     // $clog2(CYCLES_PER_SAMPLE)
    parameter int CELL_DIV     = 6;      // SPDIF cell = 6 sysclk (768 = 128 x 6)

    //--- Partials and issue slots (design doc terminology) ----------
    // The FPGA generates PARTIALS (256 of them), one per issue slot
    // through the time-division-multiplexed partial pipeline. The
    // ESP32 groups partials into voices; the FPGA never sees that.
    parameter int NUM_PARTIALS = 256;
    parameter int PARTIAL_W       = 8;      // $clog2(NUM_PARTIALS)
    parameter int UNISON       = 8;      // firmware convention only
    parameter int POLYPHONY    = 32;     // firmware convention only

    // Time slot where partial 0 enters the pipeline
    parameter int FIRST_ISSUE_SLOT    = 0;
    // Time slot where a pending ping-pong page swap executes: the
    // partial pipeline (a 281-slot span, see partial_pipeline.sv) is
    // drained there, so every
    // sample reads one consistent page.
    parameter int SWAP_SLOT    = 512;

    //--- SPI memory map (docs/memory_map.md) ------------------------
    parameter int          MAP_AW_BACKED   = 11;       // 2048-word window
    parameter logic [7:0]  SPI_ID_BYTE     = 8'hA5;
    parameter logic [15:0] MAP_CTRL_ADDR   = 16'h0002; // bit 0: swap request
    parameter logic [15:0] MAP_PARTIAL_BASE   = 16'h2000; // per-partial params
    parameter int          MAP_PARTIAL_STRIDE = 64;       // words per partial

    //--- DMEM (docs/dmem_architecture.md) ---------------------------
    parameter logic [15:0] MAP_DMEM_BASE = 16'h0800;    // DMEM base registers
    parameter int          DMEM_WORDS    = 512;         // uniform pool
    parameter int          DMEM_W        = 18;          // signed Q8.10

    //--- Instruction table (B4/B5) -------------------------------------
    // 256 entries x 4 words, stride 4, at 0x0100-0x04FF. Config is
    // wiring, so it rides the ping-pong pages (law 4).
    //   +0 CFG:   [3:0] opcode bitmask (0x0 off, 0xE LFO, 0xF ADSR,
    //             0xD MAC — OPC_* below), [5:4] LFO shape
    //             (osc_core: saw/pulse/tri/sine), [15:6] target DMEM word,
    //             LFO: [31:16] rate, added to the 25-bit phase
    //                  accumulator (2.86 mHz steps, 187.5 Hz max)
    //             ADSR: [25:16] gate DMEM word (watched, level-sensitive:
    //                   value > 0 = held)
    //             MAC: [25:16] source DMEM word
    //   +1 RATES (ADSR): [17:0] kA, [31:18] kD[13:0] — linear
    //             coefficients (dsp/adsr.sv)
    //   +2 COEF:  [17:0] signed Q2.16 coefficient, 0x10000 = unity
    //   +3 RATES2 (ADSR): [3:0] kD[17:14], [21:4] kR, [31:22] sustain
    // An instruction's OUTPUT uses the previous sample's state (the
    // one-sample lag keeps every multiply's operands registered).
    // Pool 256, FULL RATE: the CSP retires one instruction per
    // cycle, so all 256 entries execute every sample — 256 of the
    // sample's 768 cycles — and every source updates at 96 kHz.
    // A chain (sources plus the MAC instructions sharing their target) may be
    // placed anywhere in the table and tolerates gaps of up to three
    // slots, the depth of the accumulator's forwarding history.
    // Region 0x0100..0x04FF (stride 4); a pass is the whole table.
    parameter logic [15:0] MAP_IMEM_BASE = 16'h0100;
    parameter int          NUM_INSTR = 256;

    // CSP opcode = a bitmask of enables, not an enum. Each bit turns
    // on one part of the datapath, so decode is enables rather than a mux
    // tree and a new instruction is an encoding rather than a new case.
    parameter int OPC_SOURCE = 0;   // reads a source operand (MAC, ADSR gate)
    parameter int OPC_STATE  = 1;   // has persistent state (LFO, ADSR)
    parameter int OPC_MUL    = 2;   // multiplies the operand by COEF
    parameter int OPC_ACCUM  = 3;   // accumulates onto the target, vs load init
    // An envelope is the instruction that watches a gate, so STATE+SOURCE
    // means envelope and STATE alone means phase accumulator -- no fifth bit
    // is needed and the opcode still fits CFG[3:0].
    parameter logic [3:0] OPC_OFF  = 4'h0;
    parameter logic [3:0] OPC_LFO  = 4'hE;  // state + mul + accum
    parameter logic [3:0] OPC_ADSR = 4'hF;  // source + state + mul + accum
    parameter logic [3:0] OPC_MAC = 4'hD;  // source + mul + accum

    //--- Filter stability clamp --------------------------------------
    // Instability comes from HEAVY DAMPING (low Q = high q1), not
    // from resonance — theory and the autocorrelation bench agree.
    //
    //   FC_MAX = 0x2B20 = 14.4 kHz: one measured-clean step of
    //   margin below the resonance bloom that precedes the
    //   16 kHz wall. Measured at q1 = sqrt(2), the heaviest damping
    //   any resonance code decodes to: clean through 15.7 kHz,
    //   limit-cycles at 16.4 kHz, chaos at 19.5 kHz.
    //
    // No separate q1 clamp is needed: with log2-encoded resonance
    // (r octaves of Q above Butterworth, q1 = sqrt2 * 2^-r via
    // q1_lut), r = 0 IS Butterworth and no code decodes heavier, so
    // the sqrt(2) bound is structural. The high-Q
    // end stays open by design: at the top of the range the decode
    // underflows q1 to zero — self-oscillation as a feature.
    parameter logic [13:0] FC_MAX = 14'h2B20;

    //--- Number formats (design doc) ---------------------------------
    parameter int OSC_W = 24;       // UQ0.24 phase accumulator
    typedef logic signed [OSC_W-1:0] osc_t;

    parameter int CTRL_W = 14;      // UQ4.10 pitch/cutoff

    parameter int AUDIO_W = 18;     // Q4.14 audio transport
    typedef logic signed [AUDIO_W-1:0] sample_t;

    parameter int SVF_W = 36;       // Q8.28 filter states

    parameter int AUDIO_SHIFT = 14;

endpackage
