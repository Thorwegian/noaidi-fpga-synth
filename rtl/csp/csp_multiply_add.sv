//------------------------------------------------------------------------
// csp_multiply_add.sv — the CSP's multiply-add unit: product = a × b + c,
//                       with the registers on its pins placed beside it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One MULTALU36X18 DSP block, the primitive the fixed-function envelope
// (tb/csp_cosim/adsr_reference.sv) used for its RC step: an 18-bit × 36-bit
// signed product plus a 54-bit addend, register to register inside the
// block: the operands go into its own input registers (AREG, BREG, CREG:
// the core's E3) and the sum into its output register (OUT_REG: E4).
//
// The registers on the block's pins are the unit's own and placed beside
// it, flip-flop by flip-flop (csp_placed_dff.sv), on the fabric rows
// above and below the DSP row, over the nine columns the block spans:
// the operands as the core chooses them in E1 go into the operand
// registers (E2: 108 flip-flops, on the input pins), and the output
// register's sum goes into the product register (E5: 54 flip-flops), from
// where the core reduces it. The tool times no path into or out of a
// DSP's pins (docs/csp_isa.md section 12), and placed by it alone those
// registers sat 13–19 tiles from the pins; a combinational multiply from
// fabric flops failed on the board from 69 MHz while the report said 80.
// SITE_X, SITE_Y name the DSP macro the registers go beside (19, 36:
// "X19Y36"); negative leaves them to the placer, and PLACE_OPERANDS and
// PLACE_PRODUCT choose which of the two registers is placed (the 108
// operand flip-flops on the rows beside the DSP took the decode logic's
// room, issue #222; the 54 of the product are what the board's results
// line up with: the bitstreams that played had the sum's registers near
// the block). The block itself is not constrained (below); the placed
// registers draw it to the site.
//
// In the CSP's formats (docs/csp_manual.md section 3): a is a word
// (Q4.14), b a wide value (Q4.32) and c the accumulator's format
// (Q8.46); the product of the first two is Q8.46 already, so the sum
// needs no shifting. The sum wraps at 54 bits inside the block; the
// write-back stage detects that from the operands' signs, from the
// operand registers' values (operand_a … c, E2's) that the core copies on.
//
// The block is instantiated by hand because yosys only maps bare
// multiplies to DSPs (see tb/csp_cosim/adsr_reference.sv): every parameter
// is spelled out, for the same reason given there.
//------------------------------------------------------------------------
`default_nettype none
module csp_multiply_add #(
    parameter int SITE_X         = -1,    // the DSP macro's column, or negative
    parameter int SITE_Y         = -1,    // and row
    parameter bit PLACE_OPERANDS = 1'b1,  // the operand registers on the rows beside it
    parameter bit PLACE_PRODUCT  = 1'b1   // the product register likewise
) (
    input  wire                clk,
    input  wire                reset_n,
    // the operands as chosen (E1): into the operand registers this clock
    input  wire signed [17:0]  a,
    input  wire signed [35:0]  b,
    input  wire signed [53:0]  c,
    // the operand registers (E2), on the block's pins
    output logic signed [17:0] operand_a,
    output logic signed [35:0] operand_b,
    output logic signed [53:0] operand_c,
    // the sum, in the product register (E5): three clocks after the operands
    output logic signed [53:0] product
);

    // Gowin's behavioural model needs a GSR instance somewhere up the
    // hierarchy; it lives here, as it did in the envelope unit, so no
    // testbench has to know. Simulation only: in silicon the global
    // set/reset network is device infrastructure.
`ifdef SIM_GOWIN_PRIM
    GSR GSR (.GSRI(1'b1));
`endif

    // The unit's flip-flops: the operands {c, b, a}, then the product. Flop
    // n goes to tile n / 6, slot n % 6; tile t is column t % 9 of the nine
    // the block spans, row t / 9 of the rows beside the block, nearest
    // first (Y−1, Y+1, Y−2, Y+2).
    localparam int OPERAND_BITS = 18 + 36 + 54;
    localparam int PRODUCT_LOW  = OPERAND_BITS;
    localparam int FLOPS        = OPERAND_BITS + 54;
    localparam bit PLACED       = SITE_X >= 0 && SITE_Y >= 0;

    function automatic int tile_x(input int t);
        tile_x = PLACED ? SITE_X + t % 9 : -1;
    endfunction
    function automatic int tile_y(input int t);
        tile_y = !PLACED ? -1
               : t / 9 == 0 ? SITE_Y - 1 : t / 9 == 1 ? SITE_Y + 1 : t / 9 == 2 ? SITE_Y - 2 : SITE_Y + 2;
    endfunction

    wire  [OPERAND_BITS-1:0] operands_in = {c, b, a};
    logic [OPERAND_BITS-1:0] operands_q;
    assign operand_a = operands_q[17:0];
    assign operand_b = operands_q[53:18];
    assign operand_c = operands_q[107:54];
    logic signed [53:0]      block_out;    // the block's output register (OUT_REG)
    wire  [54:0]             cascade_unused;

`ifdef SYNTHESIS
    `define CSP_MAC_PRIMITIVE
`elsif SIM_GOWIN_PRIM
    `define CSP_MAC_PRIMITIVE
`endif
`ifdef CSP_MAC_PRIMITIVE
    for (genvar n = 0; n < FLOPS; n++) begin : g_flop
        localparam bit PLACE = n < PRODUCT_LOW ? PLACE_OPERANDS : PLACE_PRODUCT;
        localparam int X = PLACE ? tile_x(n / 6) : -1;
        localparam int Y = PLACE ? tile_y(n / 6) : -1;
        if (n < PRODUCT_LOW) begin : g_operand
            csp_placed_dff #(.TILE_X(X), .TILE_Y(Y), .SLOT(n % 6)) u_flop (
                .clk          (clk),
                .clock_enable (1'b1),
                .clear        (1'b0),
                .d            (operands_in[n]),
                .q            (operands_q[n])
            );
        end else begin : g_product
            csp_placed_dff #(.TILE_X(X), .TILE_Y(Y), .SLOT(n % 6)) u_flop (
                .clk          (clk),
                .clock_enable (1'b1),
                .clear        (1'b0),
                .d            (block_out[n - PRODUCT_LOW]),
                .q            (product[n - PRODUCT_LOW])
            );
        end
    end
`else
    initial begin
        operands_q = '0;
        product    = '0;
    end
    always_ff @(posedge clk) begin
        operands_q <= operands_in;
        product    <= block_out;
    end
`endif

    // The block itself carries no placement: nextpnr packs a MULTALU36X18
    // with auxiliary cells of the DSP macro, and with the block constrained
    // those are left unbound ("Found unbound cell … of type DUMMY_CELL").
    // With 162 placed flip-flops around the site the placer puts the block
    // there of its own accord; tools/lab/pin_distance.py shows whether it
    // did (every pin-driving flop within three tiles).
    MULTALU36X18 #(
        .AREG              (1'b1),   // the operands registered inside the block (the core's E3)
        .BREG              (1'b1),
        .CREG              (1'b1),
        .ASIGN_REG         (1'b0),
        .BSIGN_REG         (1'b0),
        .ACCLOAD_REG0      (1'b0),
        .ACCLOAD_REG1      (1'b0),
        .OUT_REG           (1'b1),   // the sum registered inside the block (the core's E4)
        .PIPE_REG          (1'b0),
        .C_ADD_SUB         (1'b0),   // add c
        .MULTALU36X18_MODE (0),      // a × b ± c
        .MULT_RESET_MODE   ("SYNC")
    ) u_multiply_add (
        .A       (operand_a),
        .B       (operand_b),
        .C       (operand_c),
        .ASIGN   (1'b1),
        .BSIGN   (1'b1),
        .ACCLOAD (1'b0),
        .CASI    (55'd0),
        .CLK     (clk),
        .CE      (1'b1),
        .RESET   (~reset_n),
        .DOUT    (block_out),
        .CASO    (cascade_unused)
    );

endmodule
`default_nettype wire
