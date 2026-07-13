//--------------------------------------------------------------------
// lut_interp.sv — Dual-read BRAM LUT with linear interpolation
//
// Reads two adjacent 60-bit coefficient entries and linearly
// interpolates between them. All combinational — no pipeline
// registers, no clock. Same timing contract as the current SVF.
//
// LUT: 160 fc entries × 8 Q rows = 1280 entries
//   Packed: {K[23:0], inv_res_K[17:0], inv_div[17:0]}
//   fc spacing: 16/octave (100 cents)
//
// Interpolation is per-field:
//   val = val_lo + (fc_frac/256) × (val_hi − val_lo)
// 3 DSP multiplies total.
//
// Clamp: fc_int >= 159 → addr_hi = addr_lo → no lerp at boundary.
//--------------------------------------------------------------------

module lut_interp (
    input  logic        [7:0]  fc_int,     // fc index 0–159
    input  logic        [7:0]  fc_frac,    // fractional 0–255 for lerp
    input  logic        [2:0]  q_in,       // Q row 0–7
    output logic        [23:0] K,          // Q0.24 unsigned
    output logic signed [17:0] inv_res_K,  // Q3.14 signed
    output logic signed [17:0] inv_div     // Q3.14 signed
);

    // LUT — combinational read (same pattern as current svf.sv)
    localparam ENTRIES = 1280;
    localparam Q_STRIDE = 8;
    localparam FC_MAX = 8'd159;

    reg [59:0] coeff_lut [0:ENTRIES-1];
    initial $readmemh("src/voice/svf_coeff_lut.hex", coeff_lut);

    // Addresses: lo = current entry, hi = next (both clamped at boundary)
    wire [7:0] fc_lo   = (fc_int >= FC_MAX) ? FC_MAX : fc_int;
    wire [7:0] fc_next = (fc_int >= FC_MAX) ? FC_MAX : fc_int + 8'd1;
    wire [10:0] addr_lo = fc_lo   * Q_STRIDE + q_in;
    wire [10:0] addr_hi = fc_next * Q_STRIDE + q_in;

    // Unpack lo entry
    wire        [23:0] K_lo         = coeff_lut[addr_lo][59:36];
    wire signed [17:0] inv_res_K_lo = coeff_lut[addr_lo][35:18];
    wire signed [17:0] inv_div_lo   = coeff_lut[addr_lo][17:0];

    // Unpack hi entry
    wire        [23:0] K_hi         = coeff_lut[addr_hi][59:36];
    wire signed [17:0] inv_res_K_hi = coeff_lut[addr_hi][35:18];
    wire signed [17:0] inv_div_hi   = coeff_lut[addr_hi][17:0];

    // Per-field deltas
    wire signed [24:0] dK     = {1'b0, K_hi}         - {1'b0, K_lo};         // unsigned → 25-bit signed
    wire signed [18:0] d_res  = {inv_res_K_hi[17], inv_res_K_hi} - {inv_res_K_lo[17], inv_res_K_lo};   // 19-bit
    wire signed [18:0] d_div  = {inv_div_hi[17],   inv_div_hi}   - {inv_div_lo[17],   inv_div_lo};     // 19-bit

    // frac × delta — 3 DSP multiplies
    //   {1'b0, fc_frac} = 9-bit signed, dK = 25-bit signed → 34-bit
    //   {1'b0, fc_frac} = 9-bit signed, d_* = 19-bit signed → 28-bit
    wire signed [33:0] mK    = $signed({1'b0, fc_frac}) * dK;     // 9 × 25 = 34-bit
    wire signed [27:0] m_res = $signed({1'b0, fc_frac}) * d_res;  // 9 × 19 = 28-bit
    wire signed [27:0] m_div = $signed({1'b0, fc_frac}) * d_div;  // 9 × 19 = 28-bit

    // Interpolated outputs: lo + (frac × delta) >> 8
    assign K         = K_lo         + mK[31:8];    // 24-bit
    assign inv_res_K = inv_res_K_lo + m_res[25:8]; // 18-bit
    assign inv_div   = inv_div_lo   + m_div[25:8]; // 18-bit

endmodule
