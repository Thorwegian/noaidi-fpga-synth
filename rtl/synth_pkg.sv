// params_pkg.sv — Shared design parameters

package synth_pkg;

    parameter int SAMPLE_RATE = 96000;

    parameter int OSC_W = 24;       // Q0.24
    typedef logic signed [OSC_W-1:0] osc_t;
    
    parameter int AUDIO_W = 18;     // Q4.14
    typedef logic signed [AUDIO_W-1:0] sample_t;

    parameter int AUDIO_SHIFT = 14;

endpackage