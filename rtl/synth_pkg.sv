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

    //--- SPI memory map (docs/memory_map.md) ------------------------
    parameter logic [7:0]  SPI_ID_BYTE     = 8'hA5;
    parameter logic [15:0] MAP_CTRL_ADDR   = 16'h0002; // [0] commit the write queue, [1] hold the CSP, [2] test tone
    parameter logic [15:0] MAP_PROGRAM_HIGH_ADDR = 16'h0010; // bits 35:32 of the next instruction
    parameter logic [15:0] MAP_PARTIAL_BASE   = 16'h2000; // a partial's pointers: + 64 p, four words
    parameter int          MAP_PARTIAL_STRIDE = 64;       // words per partial
    parameter logic [15:0] MAP_QUEUE_BASE  = 16'h6000; // the CSP's write queue: + register or sink address
    parameter logic [15:0] MAP_PROGRAM_BASE = 16'h8000; // the CSP's instruction memory: + pc

    //--- Partial sinks (docs/csp_isa.md section 6) --------------------
    // A partial reads ten sink words, named by ten pointers into the sink
    // area, over two cycles. Words are Q4.14; pitch and cutoff are
    // octaves from the reference below, the gains linear.
    parameter int POINTER_W            = 10;    // $clog2(sink words)
    parameter int POINTERS_PER_PARTIAL = 10;
    // The last word of the sink area, which nobody writes: always zero.
    parameter logic [9:0] POINTER_ZERO = 10'h3FF;
    parameter int POINTER_ENTRY_W      = POINTER_W * POINTERS_PER_PARTIAL;
    parameter int CYCLES_PER_PARTIAL   = 2;
    parameter int SINK_READ_PORTS      = 6;     // a cycle's worth of the sink area
    // The pointers of a partial, by position in its entry.
    parameter int POINTER_PITCH_VOICE   = 0;    // the voice's pitch
    parameter int POINTER_PITCH_CHANNEL = 1;    //   and the oscillator's detune
    parameter int POINTER_CUTOFF_VOICE  = 2;
    parameter int POINTER_CUTOFF_CHANNEL = 3;   // the tracking of tune and detune
    parameter int POINTER_GAIN_VOICE    = 4;    // envelope × velocity
    parameter int POINTER_GAIN_LEFT     = 5;    // the channel's side of it
    parameter int POINTER_GAIN_RIGHT    = 6;
    parameter int POINTER_DUTY          = 7;
    parameter int POINTER_RESONANCE     = 8;
    parameter int POINTER_MODE          = 9;    // waveform, cascade, filter type
    // Octave zero of the pitch and cutoff sinks: middle C (MIDI note 60),
    // in the pipeline's UQ4.10 log2 pitch.
    parameter logic [13:0] PITCH_REFERENCE = 14'h1400;

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
