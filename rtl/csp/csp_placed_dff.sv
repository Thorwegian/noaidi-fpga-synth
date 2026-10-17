//------------------------------------------------------------------------
// csp_placed_dff.sv — one flip-flop at a named slot of a named tile
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A Gowin DFF placed by a BEL attribute ("X13Y26/DFF2"), with the LUT in
// front of it placed on the slot's own LUT ("X13Y26/LUT2"): the register
// stages on a block RAM's pins, in and out, are built from these, next to
// the block, because the place-and-route tool times no path into or out
// of such a pin and otherwise leaves the flip-flop with the logic that
// feeds it (csp_bank.sv, docs/gowin_oss_notes.md). The attribute has to
// be a constant of the module holding the instance, hence a module of one
// flip-flop, with the tile's coordinates as numbers (TILE_X, TILE_Y: a
// negative one leaves the flip-flop to the placer; an empty attribute is
// not "unplaced" to the tool but an assertion, so none goes on then).
//
// The LUT is the flip-flop's anchor: nextpnr pairs every flip-flop with
// the LUT that feeds it (a passthrough LUT inserted where there is none)
// and places the pair by the LUT, so a flip-flop constrained alone was
// carried off to wherever its driver went (13 tiles, on the first build
// with placed flip-flops). The LUT is a passthrough, or with HOLDS the
// mux that holds the flip-flop while the clock enable is low (a waiting
// instruction's address), or with CLEARS as well the mux with a
// synchronous clear before it (a pointer that a reset returns to zero) —
// nextpnr takes no DFFE, DFFR or DFFC on a slot it calls a DFF.
// Initialised to 0, as the fabric's flip-flops are at configuration.
//------------------------------------------------------------------------
`default_nettype none
module csp_placed_dff #(
    parameter int TILE_X = -1,                        // the tile's column, or negative
    parameter int TILE_Y = -1,                        // and row
    parameter int SLOT   = 0,                         // 0 … 5: the tile's flip-flops
    parameter bit HOLDS  = 1'b0,                      // the clock enable is used
    parameter bit CLEARS = 1'b0                       // the clear is used (with HOLDS)
) (
    input  wire  clk,
    input  wire  clock_enable,
    input  wire  clear,                               // synchronous, over the enable
    input  wire  d,
    output logic q
);

`ifdef SYNTHESIS
    `define CSP_DFF_PRIMITIVE
`elsif SIM_GOWIN_PRIM
    `define CSP_DFF_PRIMITIVE
`endif
`ifdef CSP_DFF_PRIMITIVE
`ifndef SYNTHESIS
    // Gowin's behavioural model reads GSR.GSRO upward through the hierarchy,
    // and with more than one GSR instance in the design (the multiplier's,
    // a bench's) Verilator finds none from here; one of the flip-flop's own
    // is unambiguous.
    GSR GSR (.GSRI(1'b1));
`endif
    localparam bit PLACED   = TILE_X >= 0 && TILE_Y >= 0;
    localparam     FLOP_BEL = $sformatf("X%0dY%0d/DFF%0d", TILE_X, TILE_Y, SLOT);
    localparam     LUT_BEL  = $sformatf("X%0dY%0d/LUT%0d", TILE_X, TILE_Y, SLOT);
    // The LUTs, by their input index {I3, I2, I1, I0}: the passthrough
    // F = I0; the mux F = I2 ? I0 : I1 (the enable on I2); the clearing mux
    // F = I3 ? 0 : (I2 ? I0 : I1) (the clear on I3).
    localparam logic [1:0]  PASS_INIT  = 2'b10;
    localparam logic [7:0]  MUX_INIT   = 8'hAC;
    localparam logic [15:0] CLEAR_INIT = 16'h00AC;
    wire next;
    if (PLACED) begin : g_placed
        if (CLEARS) begin : g_clear
            (* BEL = LUT_BEL, keep *)
            LUT4 #(.INIT(CLEAR_INIT)) u_lut (.F(next), .I0(d), .I1(q), .I2(clock_enable), .I3(clear));
        end else if (HOLDS) begin : g_mux
            (* BEL = LUT_BEL, keep *)
            LUT3 #(.INIT(MUX_INIT)) u_lut (.F(next), .I0(d), .I1(q), .I2(clock_enable));
        end else begin : g_pass
            (* BEL = LUT_BEL, keep *)
            LUT1 #(.INIT(PASS_INIT)) u_lut (.F(next), .I0(d));
        end
        (* BEL = FLOP_BEL, keep *)
        DFF u_flop (
            .CLK (clk),
            .D   (next),
            .Q   (q)
        );
    end else begin : g_free
        if (CLEARS) begin : g_clear
            (* keep *)
            LUT4 #(.INIT(CLEAR_INIT)) u_lut (.F(next), .I0(d), .I1(q), .I2(clock_enable), .I3(clear));
        end else if (HOLDS) begin : g_mux
            (* keep *)
            LUT3 #(.INIT(MUX_INIT)) u_lut (.F(next), .I0(d), .I1(q), .I2(clock_enable));
        end else begin : g_pass
            (* keep *)
            LUT1 #(.INIT(PASS_INIT)) u_lut (.F(next), .I0(d));
        end
        (* keep *)
        DFF u_flop (
            .CLK (clk),
            .D   (next),
            .Q   (q)
        );
    end
`else
    initial q = 1'b0;
    always_ff @(posedge clk) begin
        if (CLEARS && clear) begin
            q <= 1'b0;
        end else if (!HOLDS || clock_enable) begin
            q <= d;
        end
    end
`endif

endmodule
`default_nettype wire
