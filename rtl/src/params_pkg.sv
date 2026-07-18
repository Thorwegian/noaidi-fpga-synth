// params_pkg.sv — Shared design parameters

package params_pkg;

    parameter int SAMPLE_RATE   = 96000;

    parameter int AUDIO_W = 18;   // Q3.14
    typedef logic signed [AUDIO_W-1:0]   sample_t;

    parameter int AUDIO_SHIFT = 14;

endpackage