//------------------------------------------------------------------------
// limiter.sv -- log-domain peak limiter, PIPELINED per-step function (#121).
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Everything lives in att_lut's log-gain grid: 16 code units per octave
// (6.02 dB), 0.375 dB per unit. No division anywhere:
//   level_code = octave(level)*16 + log_lut[4 bits under the leading 1]
//   target     = max(0, level_code - thresh_code)      "dB over threshold"
//   gain_q     slews toward target<<SUB (attack up / release down)
//   gain_lin   = att_lut[code[3:0]] >> code[7:4]       (UQ0.16)
//
// FIVE registered stages -- the silicon timing rule (AGENTS.md): never
// chain a LUT + barrel shift into arithmetic in one cycle; the first,
// combinational version of this module did exactly that and sputtered
// on hardware (2026-09-18) while STA passed.
//   S1a  octave: priority encoder            (decode)
//   S1b  mantissa shift + log_lut -> code    (barrel shift + LUT)
//   S2a  target = code - threshold, clamped  (adds)
//   S2b  slew toward target -> gain_q_out    (adds/compares)
//   S3   att_lut + shift -> gain_lin         (LUT + barrel shift)
// Latency: present `level` (and hold it) at cycle 0 -> gain_q_out valid
// from cycle 4, gain_lin from cycle 5. The state (gain_q, the envelope)
// is OWNED BY THE INSTANTIATOR -- a register for the master, a per-
// element RAM for the filter -- so one module serves both; for a
// streaming instance the stages simply pipeline. `level` and the gained
// signal are separate ports: feedforward / feedback / external sidechain
// is wiring, not a mode. Bit-faithful to scripts/limiter_model.py.
//------------------------------------------------------------------------
`default_nettype none
module limiter #(
    parameter int LEVEL_W = 26,
    parameter int SUB     = 10          // sub-step bits: fractional slew
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire  [LEVEL_W-1:0] level,          // unsigned magnitude (hold it)
    input  wire  [7+SUB:0]     gain_q_in,      // state: code[7:0] . sub[SUB-1:0]
    input  wire  [7:0]         thresh_code,
    input  wire  [7+SUB:0]     attack_q,       // slew per step, sub-units
    input  wire  [7+SUB:0]     release_q,
    output logic [7+SUB:0]     gain_q_out,     // S2b register
    output logic [16:0]        gain_lin        // S3 register, UQ0.16
);
    localparam int OW = $clog2(LEVEL_W);       // octave width

    reg [3:0]  log_lut [0:15];
    reg [16:0] att_lut [0:15];
    initial begin
        $readmemh("element/log_lut.hex", log_lut);
        $readmemh("element/att_lut.hex", att_lut);
    end

    // ---- S1a: octave = index of the leading 1 ----
    logic [OW-1:0]      oct_c;
    logic               nz_c;
    always_comb begin
        oct_c = '0; nz_c = 1'b0;
        for (int i = 0; i < LEVEL_W; i++)
            if (level[i]) begin oct_c = OW'(i); nz_c = 1'b1; end
    end
    logic [OW-1:0]      s1_oct;
    logic               s1_nz;
    logic [LEVEL_W-1:0] s1_level;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin s1_oct <= '0; s1_nz <= 1'b0; s1_level <= '0; end
        else        begin s1_oct <= oct_c; s1_nz <= nz_c; s1_level <= level; end

    // ---- S1b: 4 bits under the leading 1 -> log fraction -> level_code ----
    logic [LEVEL_W-1:0] lsh_c;
    always_comb begin
        if (s1_oct >= OW'(4)) lsh_c = s1_level >> (s1_oct - OW'(4));
        else                  lsh_c = s1_level << (OW'(4) - s1_oct);
    end
    logic [OW+4:0] s2_code;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) s2_code <= '0;
        else        s2_code <= s1_nz ? ({s1_oct, 4'd0} + (OW+5)'(log_lut[lsh_c[3:0]])) : '0;

    // ---- S2a: target = dB over threshold, clamped to the 8-bit code ----
    logic [7:0] target_c;
    always_comb begin
        if (s2_code > (OW+5)'(thresh_code)) begin
            if (s2_code - (OW+5)'(thresh_code) > (OW+5)'(255)) target_c = 8'd255;
            else target_c = 8'(s2_code - (OW+5)'(thresh_code));
        end else target_c = 8'd0;
    end
    logic [7:0] s3_target;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) s3_target <= '0;
        else        s3_target <= target_c;

    // ---- S2b: slew toward target<<SUB, bounded per step ----
    wire [7+SUB:0] tq = {s3_target, {SUB{1'b0}}};
    logic [7+SUB:0] gq_c;
    always_comb begin
        if (tq > gain_q_in) gq_c = (tq - gain_q_in > attack_q)  ? gain_q_in + attack_q  : tq;
        else                gq_c = (gain_q_in - tq > release_q) ? gain_q_in - release_q : tq;
    end
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) gain_q_out <= '0;
        else        gain_q_out <= gq_c;

    // ---- S3: decode: 6 dB per int (shift), 0.375 dB per frac (LUT) ----
    wire [7:0] code = gain_q_out[7+SUB:SUB];
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) gain_lin <= 17'h10000;
        else        gain_lin <= att_lut[code[3:0]] >> code[7:4];

endmodule
`default_nettype wire
