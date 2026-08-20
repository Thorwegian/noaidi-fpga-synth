// synth_pkg.sv — Shared design parameters

package synth_pkg;

    parameter int SAMPLE_RATE = 96000;
    parameter int SYS_CLK_HZ  = 98_304_000;

    //--- Drum (SCMO) scheduling -------------------------------------
    parameter int DRUM_CYCLES  = 1024;   // SYS_CLK_HZ / SAMPLE_RATE
    parameter int DRUM_W       = 10;     // $clog2(DRUM_CYCLES)

    parameter int NUM_VOICES   = 256;    // 32-note polyphony × 8 unison
    parameter int VOICE_W      = 8;      // $clog2(NUM_VOICES)
    parameter int UNISON       = 8;
    parameter int POLYPHONY    = 32;

    // Drum slot where voice 0 enters the pipeline
    parameter int VOICE_BASE   = 0;
    // Pipeline stages per voice (S0..S11)
    parameter int VOICE_STAGES = 12;
    // Contiguous drum span occupied by the voice pipeline
    parameter int VOICE_SPAN   = NUM_VOICES + VOICE_STAGES - 1;

    //--- Number formats (design doc) ---------------------------------
    parameter int OSC_W = 24;       // UQ0.24 phase accumulator
    typedef logic signed [OSC_W-1:0] osc_t;

    parameter int CTRL_W = 14;      // UQ4.10 pitch/cutoff

    parameter int AUDIO_W = 18;     // Q2.16 audio transport
    typedef logic signed [AUDIO_W-1:0] sample_t;

    parameter int SVF_W = 36;       // Q8.28 filter states

    parameter int AUDIO_SHIFT = 14;

endpackage