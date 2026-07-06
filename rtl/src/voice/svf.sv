//--------------------------------------------------------------------
// svf.sv — Bilinear State Variable Filter
//
// Lazzarini & Timoney, "Improving the Chamberlin Digital State
// Variable Filter", Journal of the Audio Engineering Society, 2022.
//
// === Bit width rationale ===
//
// All signals are 18-bit Q3.14 unless noted otherwise. This is the
// widest format that fits a single Gowin DSP18 multiplier macro.
//
// K (24-bit Q0.24 unsigned):
//   K = tan(pi * fc / fs). A 1-bit error at 50 Hz shifts the cutoff
//   by tens of cents. 24 fractional bits gives < 0.1 cent error
//   across the musical range (18 Hz–18 kHz). This is the only
//   parameter that needs this much precision — it directly sets
//   the filter tuning. K is unsigned because it is always < 1 for
//   fc < fs/2 (practical cutoff range). `$signed()` is used before
//   multiplication to avoid Verilog unsigned×signed corruption.
//
// inv_res_K, inv_div (18-bit Q3.14 signed):
//   Derived from K and Q. Q controls resonance, not tuning — the
//   ear tolerates >1% error. 14 fractional bits is overkill for
//   this purpose. Signed Q3.14 because 1/Q+K can exceed 1.0
//   (Q < 3 pushes it above unity).
//
// Audio and states (18-bit Q3.14):
//   Q3.14 gives ±8 range with 14 fractional bits. At Q=6 the
//   states peak at ±0.44 — 18× margin. Even at Q=20 the states
//   would stay in range. 18 bits also keeps all multiplies in
//   single DSP18 macros (no cascading).
//
// === Multiplier summary ===
//   inv_res_K × s1    Q3.14 × Q3.14  18×18  1 DSP   shift 14
//   inv_div   × hp_arg Q3.14 × Q3.14  18×18  1 DSP   shift 14
//   K         × hp    Q0.24 × Q3.14  24×18  1 DSP   shift 24
//   K         × bp    Q0.24 × Q3.14  24×18  1 DSP   shift 24
//--------------------------------------------------------------------

module svf (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    strobe,

    input  logic signed [17:0]      sample_in,     // Q3.14 audio input
    input  logic        [23:0]      K,             // Q0.24 unsigned (tan)
    input  logic signed [17:0]      inv_res_K,     // Q3.14  1/Q + K
    input  logic signed [17:0]      inv_div,       // Q3.14  1/(1 + K/Q + K²)

    output logic signed [17:0]      sample_out     // Q3.14 lowpass
);

    // Integrator states.
    logic signed [17:0] s1, s2;

    // ---- Feedback:  (1/Q + K) × s1  ----
    wire signed [35:0] m_fb1 = inv_res_K * s1;
    wire signed [17:0] fb1   = $signed(m_fb1[31:14]);

    // ---- Highpass:  inv_div × (x - fb1 - s2)  ----
    wire signed [35:0] m_hp = inv_div * (sample_in - fb1 - s2);
    wire signed [17:0] hp   = $signed(m_hp[31:14]);

    // ---- First integrator:  K × hp  ----
    wire signed [41:0] m_u1 = $signed(K) * hp;
    wire signed [17:0] u1   = $signed(m_u1[41:24]);

    wire signed [17:0] bp = u1 + s1;

    // ---- Second integrator:  K × bp  ----
    wire signed [41:0] m_u2 = $signed(K) * bp;
    wire signed [17:0] u2   = $signed(m_u2[41:24]);

    wire signed [17:0] lp = u2 + s2;

    //----------------------------------------------------------------
    // Bilinear integrator update:  state_new = input + output
    //   output = input + state  →  state_new = 2×input + state
    //----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1 <= 0; s2 <= 0; sample_out <= 0;
        end else if (strobe) begin
            s1 <= u1 + bp;
            s2 <= u2 + lp;
            sample_out <= lp;
        end
    end

endmodule
