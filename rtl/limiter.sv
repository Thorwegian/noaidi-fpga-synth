//------------------------------------------------------------------------
// limiter.sv -- log-domain peak limiter: the per-step function (#121).
//
// Everything lives in att_lut's log-gain grid: 16 code units per octave
// (6.02 dB), 0.375 dB per unit. No division anywhere:
//   level_code = octave(level)*16 + log_lut[4 bits under the leading 1]
//   target     = max(0, level_code - thresh_code)      "dB over threshold"
//   gain_q     slews toward target<<SUB (attack up / release down)
//   gain_lin   = att_lut[code[3:0]] >> code[7:4]       (UQ0.16)
// The state (gain_q, the envelope) is OWNED BY THE INSTANTIATOR -- a
// register for the master, a per-element RAM for the filter -- so one
// module serves both. `level` and the gained signal are separate ports:
// feedforward / feedback / external sidechain is wiring, not a mode.
// Transparent below threshold: target = 0, gain walks back to unity.
// Bit-faithful to scripts/limiter_model.py. Purely combinational --
// register outside (the master has 768 cycles per sample to spare).
//------------------------------------------------------------------------
`default_nettype none
module limiter #(
    parameter int LEVEL_W = 26,
    parameter int SUB     = 10          // sub-step bits: fractional slew
) (
    input  wire  [LEVEL_W-1:0] level,          // unsigned magnitude
    input  wire  [7+SUB:0]     gain_q_in,      // state: code[7:0] . sub[SUB-1:0]
    input  wire  [7:0]         thresh_code,
    input  wire  [7+SUB:0]     attack_q,       // slew per step, sub-units
    input  wire  [7+SUB:0]     release_q,
    output logic [7+SUB:0]     gain_q_out,
    output logic [16:0]        gain_lin        // UQ0.16 (17b), 0x10000 = unity
);
    localparam int OW = $clog2(LEVEL_W);       // octave width

    reg [3:0]  log_lut [0:15];
    reg [16:0] att_lut [0:15];
    initial begin
        $readmemh("element/log_lut.hex", log_lut);
        $readmemh("element/att_lut.hex", att_lut);
    end

    // octave = index of the leading 1 (priority encoder)
    logic [OW-1:0] octv;
    logic          nz;
    always_comb begin
        octv = '0; nz = 1'b0;
        for (int i = 0; i < LEVEL_W; i++)
            if (level[i]) begin octv = OW'(i); nz = 1'b1; end
    end
    // the 4 bits under the leading 1 -> log fraction
    logic [LEVEL_W-1:0] lsh;
    always_comb begin
        if (octv >= OW'(4)) lsh = level >> (octv - OW'(4));
        else                lsh = level << (OW'(4) - octv);
    end
    wire [3:0] m4 = lsh[3:0];

    // level_code on the 16/octave grid; target = dB over threshold, 0..255
    wire [OW+4:0] level_code = nz ? ({octv, 4'd0} + (OW+5)'(log_lut[m4])) : '0;
    logic [7:0] target;
    always_comb begin
        if (level_code > (OW+5)'(thresh_code)) begin
            if (level_code - (OW+5)'(thresh_code) > (OW+5)'(255)) target = 8'd255;
            else target = 8'(level_code - (OW+5)'(thresh_code));
        end else target = 8'd0;
    end

    // slew toward target<<SUB, bounded per step -> inherently stable
    wire [7+SUB:0] tq = {target, {SUB{1'b0}}};
    always_comb begin
        if (tq > gain_q_in) begin
            gain_q_out = (tq - gain_q_in > attack_q) ? gain_q_in + attack_q : tq;
        end else begin
            gain_q_out = (gain_q_in - tq > release_q) ? gain_q_in - release_q : tq;
        end
    end

    // decode the NEW code: 6 dB per int (shift), 0.375 dB per frac (LUT)
    wire [7:0] code = gain_q_out[7+SUB:SUB];
    assign gain_lin = att_lut[code[3:0]] >> code[7:4];

endmodule
`default_nettype wire
