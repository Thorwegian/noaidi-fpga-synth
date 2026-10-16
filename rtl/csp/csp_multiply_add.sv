//------------------------------------------------------------------------
// csp_multiply_add.sv — the CSP's multiply-add unit: product = a × b + c
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One MULTALU36X18 DSP block, the primitive the fixed-function envelope
// (tb/csp_cosim/adsr_reference.sv) used for its RC step: an 18-bit × 36-bit
// signed product plus a 54-bit addend.
// Combinational, with none of the block's registers: the CSP executes an
// instruction within one clock, from register file read to result
// register (rtl/csp/csp_core.sv).
//
// In the CSP's formats (docs/csp_manual.md section 3): a is a word
// (Q4.14), b a wide value (Q4.32) and c the accumulator's format
// (Q8.46); the product of the first two is Q8.46 already, so the sum
// needs no shifting. The sum wraps at 54 bits inside the block; the
// write-back stage detects that from the operands' signs.
//
// The block is instantiated by hand because yosys only maps bare
// multiplies to DSPs (see tb/csp_cosim/adsr_reference.sv): every parameter is
// spelled out,
// for the same reason given there.
//------------------------------------------------------------------------
`default_nettype none
module csp_multiply_add (
    input  wire               clk,      // unused: the block is combinational
    input  wire               reset_n,
    input  wire signed [17:0] a,
    input  wire signed [35:0] b,
    input  wire signed [53:0] c,
    output logic signed [53:0] product
);

    // Gowin's behavioural model needs a GSR instance somewhere up the
    // hierarchy; it lives here, as it did in the envelope unit, so no testbench has to
    // know. Simulation only: in silicon the global set/reset network is
    // device infrastructure.
`ifdef SIM_GOWIN_PRIM
    GSR GSR (.GSRI(1'b1));
`endif

    wire [54:0] cascade_unused;

    MULTALU36X18 #(
        .AREG              (1'b0),
        .BREG              (1'b0),
        .CREG              (1'b0),
        .ASIGN_REG         (1'b0),
        .BSIGN_REG         (1'b0),
        .ACCLOAD_REG0      (1'b0),
        .ACCLOAD_REG1      (1'b0),
        .OUT_REG           (1'b0),   // combinational: the core registers the result
        .PIPE_REG          (1'b0),
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

endmodule
`default_nettype wire
