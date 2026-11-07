//--------------------------------------------------------------------
// osc_core.sv — combinational oscillator core (waveform generation)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Pure combinational function of the ALREADY-ADVANCED phase — no
// accumulators, no registers (the pipeline owns the phase register).
// Phase and duty are Q0.24 signed.
//
//   sample_out — selected waveform, scaled Q0.24 → Q2.16
//
// The sine comes in ready-made (sine, Q2.16): the caller reads it on
// the clock from the full-wave table in block RAM (scripts/
// gen_sine_lut.py) with the same phase it registers for this module.
// The table used to be a quarter wave read without a clock, which can
// only be built from LUTs (741 of them) with a 24-bit negate after it:
// eleven LUT levels, the longest path of the oscillator stage.
//
// The phase adder belongs to the CALLER, not to this module, for two
// reasons. The caller needs the advanced phase anyway, for the state
// writeback, so holding the adder here would mean two 24-bit adders
// computing one value. And a single cycle carrying BSRAM read ->
// octave shift -> 24-bit add -> sine LUT read -> 4:1 mux is this
// design's critical path (13.04 ns against a 13.56 ns period, i.e. 4%
// margin); the caller can register the sum before asking for a
// waveform. Callers that advance phase elsewhere pass their own phase
// in.
//--------------------------------------------------------------------
`default_nettype none
module osc_core (
    input  logic signed [23:0] phase_next, // advanced phase (Q0.24)
    input  logic signed [23:0] duty,       // PWM duty cycle (Q0.24, signed)
    input  logic signed [24:0] pulse_max,   // the pulse's high level with the DC offset
                                            // removed: 2^23-1 - duty, by the caller a
                                            // stage earlier (see the pulse section)
    input  logic signed [24:0] pulse_min,   // its low level, -2^23 - duty, likewise
    input  logic        [1:0]  wave,       // 0 saw, 1 pulse, 2 tri, 3 sine
    input  logic signed [15:0] sine,       // the sine at phase_next, Q2.16, from
                                           // the caller's block RAM read

    output logic signed [17:0] sample_out  // Q2.16
);

    //----------------------------------------------------------------
    // Sawtooth: phase passthrough (signed Q0.24)
    //----------------------------------------------------------------
    logic signed [23:0] saw;
    assign saw = phase_next;

    //----------------------------------------------------------------
    // Pulse: signed comparator — phase < duty
    //   duty = -1.0 → never high, 0.0 → 50%, +1.0 → always high
    //
    // DC-FREE AT EVERY DUTY. A bare comparator is only centred at 50%.
    // phase_next sweeps the full signed range, so the comparator is true for
    // frac = (duty + 2^23)/2^24 of the cycle and the mean of a ±2^23 square
    // with that duty is
    //
    //     2^23 · (2·frac − 1)  =  duty
    //
    // exactly — the offset IS the duty word, so removing it is one subtract
    // and no multiply. At CC 25 = 127 firmware sends duty = +7549747, which is
    // 0.9 of full scale of pure DC: tens of thousands of PCM units, scaled by
    // the amp envelope on its way out, which is why it read as an envelope
    // leaking into the offset. Largely inaudible, but it spent headroom
    // permanently and a lowered cutoff removes the pulse and leaves the offset
    // behind.
    //
    // At duty 0 the correction subtracts nothing, so a square is bit-identical
    // to before.
    //
    // The DC-corrected levels, 2^23-1 - duty and -2^23 - duty, depend on duty
    // alone, so the CALLER subtracts them a stage earlier (pulse_max,
    // pulse_min) and the comparator only selects between them: the
    // compare's LUT tree no longer feeds a 25-bit carry chain, which was
    // this stage's critical path (7 LUT levels then 7 carry cells).
    //
    // 25 bits because a corrected narrow pulse reaches ~2^24. After the >>> 8
    // below that is at most ±2^16, and Q2.16 spans ±2.0 against a nominal
    // oscillator's ±0.5, so it fits without a clamp — and no clamp is added on
    // purpose, since one here would mask a width error instead of showing it.
    //----------------------------------------------------------------
    logic signed [24:0] pulse;
    // The compare as a subtract's sign, so it maps to one carry chain
    // rather than a LUT tree feeding a chain (abc's shape of `<`).
    wire signed [24:0] below = 25'(phase_next) - 25'(duty);
    assign pulse = below[24] ? pulse_max : pulse_min;

    //----------------------------------------------------------------
    // Triangle: fold sawtooth at midpoint (phase = 2^23). Modulo 2^24,
    //   (p << 1) - 2^23                 ==  (p << 1) ^ 2^23
    //   2^23-1 - ((p - 2^23) << 1)      == ~(p << 1) ^ 2^23
    // so the fold is bitwise: no carry chain, same bits as the subtracts.
    //----------------------------------------------------------------
    logic signed [23:0] triangle;
    assign triangle = (phase_next[23] ? ~(phase_next << 1) : (phase_next << 1))
                    ^ 24'h800000;

    //----------------------------------------------------------------
    // Waveform select
    //----------------------------------------------------------------
    // 25 bits so the DC-corrected pulse survives the mux; the other
    // three are sign-extended and unchanged. The sine is already the
    // output word, so it enters at bit 8 and the >>> 8 returns it.
    logic signed [24:0] muxed;
    always_comb begin
        case (wave)
            2'd0:    muxed = 25'(saw);
            2'd1:    muxed = pulse;
            2'd2:    muxed = 25'(triangle);
            default: muxed = 25'(signed'({sine, 8'b0}));
        endcase
    end

    assign sample_out = 18'(muxed >>> 8);   // Q0.24 → Q2.16

endmodule
