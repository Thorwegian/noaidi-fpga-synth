//------------------------------------------------------------------------
// csp_multiply_add.sv — the multiply-add unit: product = a × b + c
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One MULTALU36X18 DSP block: an 18-bit × 36-bit signed product plus a 54-bit
// addend, with the block's own registers as the registers on its pins
// (docs/csp2_architecture.md rule 1): the operands are sampled by AREG, BREG
// and CREG, the product settles into the pipeline register (PIPE_REG, between
// the multiplier and the ALU: UG287-1.4E figure 4-9), the sum into OUT_REG a
// cycle later, and the core captures it in a fabric register the cycle after.
// Experiment (#235): with the pipeline register bypassed the 36 × 18 multiply
// and the 54-bit add were one clock inside the block, where nothing times them. UG287-1.4E p29 and p30 (figure 4-9) give the
// registers; the macro's ports are figure 3-1 on p5.
//
// In the CSP's formats (docs/csp2_isa.md): a is a word (Q4.14), b a wide
// value (Q4.32) and c the accumulator's format (Q8.46); the product of the
// first two is Q8.46 already, so the sum needs no shifting. The sum wraps at
// 54 bits inside the block; the core's E4 detects that from the operands'
// signs (the three bits csp_core carries beside the product).
//
// The block is instantiated by hand because yosys only maps bare
// multiplies to DSPs: every parameter is spelled out. In simulation a
// behavioural model with the same three clocks of latency stands in.
//------------------------------------------------------------------------
`default_nettype none
module csp_multiply_add (
    input  wire                clk,
    input  wire                reset_n,
    input  wire signed [17:0]  a,
    input  wire signed [35:0]  b,
    input  wire signed [53:0]  c,
    output logic signed [53:0] product      // a × b + c, three clocks after the operands
);

`ifdef SYNTHESIS
    wire [54:0] cascade_unused;

    MULTALU36X18 #(
        .AREG              (1'b1),
        .BREG              (1'b1),
        .CREG              (1'b1),
        .ASIGN_REG         (1'b0),
        .BSIGN_REG         (1'b0),
        .ACCLOAD_REG0      (1'b0),
        .ACCLOAD_REG1      (1'b0),
        .OUT_REG           (1'b1),
        .PIPE_REG          (1'b1),
        .C_ADD_SUB         (1'b0),   // add c
        .MULTALU36X18_MODE (0),      // a × b ± c
        .MULT_RESET_MODE   ("SYNC")
    ) u_multiply_add (
        .A       (a),
        .B       (b),
        .C       (c),
        .ASIGN   (1'b1),
        .BSIGN   (1'b1),
        .ACCLOAD (1'b0),
        .CASI    (55'd0),
        .CLK     (clk),
        .CE      (1'b1),
        .RESET   (~reset_n),
        .DOUT    (product),
        .CASO    (cascade_unused)
    );
`else
    logic signed [17:0] a_q;
    logic signed [35:0] b_q;
    logic signed [53:0] c_q, c_pipe;
    logic signed [53:0] multiplied;
    always_ff @(posedge clk) begin
        a_q        <= a;
        b_q        <= b;
        c_q        <= c;
        multiplied <= 54'(a_q) * 54'(b_q);          // the pipeline register, between the multiplier and the ALU
        c_pipe     <= c_q;
        product    <= multiplied + c_pipe;          // wraps at 54 bits, as the block does
    end
`endif

endmodule
`default_nettype wire
