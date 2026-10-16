// dsp_probe.sv — does the place-and-route tool time a path from a DSP block?
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A multiply-add in the shape of the CSP's MAC (18 × 36 + 54), mapped to a
// DSP block with its combinational output, feeds a six-deep chain of 54-bit
// adders into a flop. nextpnr-himbaechel reports 337 MHz and a counter as
// the critical path: it does not time paths that start at a DSP output
// either. The rule in docs/csp_isa.md, 12: a DSP's product goes straight
// into a register (best its own, OUT_REG).
`default_nettype none
module dsp_probe (
    input  wire  clk,
    output logic result
);
    logic signed [17:0] a = 18'sd3, b = 18'sd5;
    logic signed [35:0] c = '0;
    always_ff @(posedge clk) begin
        a <= a + 18'sd7;
        b <= b - 18'sd3;
        c <= c + 36'sd11;
    end
    wire signed [53:0] product = a * $signed({b, 18'd0}) + c;
    logic [53:0] chain [6];
    always_comb begin
        chain[0] = product;
        for (int k = 1; k < 6; k++) chain[k] = {chain[k-1][52:0], ^chain[k-1]} + 54'd7;
    end
    always_ff @(posedge clk) result <= ^chain[5];
endmodule
`default_nettype wire
