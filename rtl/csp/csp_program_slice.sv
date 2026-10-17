//------------------------------------------------------------------------
// csp_program_slice.sv — nine bits of every instruction word, in one block,
//                        with the fetch's registers placed beside it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One of the instruction memory's four blocks (csp_instruction_memory.sv):
// 2048 × 9 in a DPX9B, written through port A on the SPI clock, fetched
// through port B on the system clock, bypass mode: the nine bits are in
// the block's own output register a clock after their address. SITE_X,
// SITE_Y place the block (22, 45: "X22Y45/BSRAM"); negative leaves it to
// the placer, and the registers with it.
//
// The registers on the block's fetch pins are the slice's own and placed
// beside it, flip-flop by flip-flop (csp_placed_dff.sv), on the tiles of
// the block's three columns in the rows above and below it: the fetch
// address goes into a register on the address pin (fetch_address: what
// the core's fetch register takes this clock, which is never held), and
// the block's nine bits go into the slice's part of the fetch buffer
// (fetch_data), taken while buffer_load and held otherwise — the core's
// buffer register, placed where the tool does not time the path to it
// (docs/csp_isa.md section 12).
//------------------------------------------------------------------------
`default_nettype none
module csp_program_slice #(
    parameter int SITE_X = -1,                        // the BSRAM site's column, or negative
    parameter int SITE_Y = -1                         // and row
) (
    input  wire                           sclk,
    input  wire                           write_enable,
    input  wire [csp_pkg::PROGRAM_W-1:0]  write_address,
    input  wire [8:0]                     write_data,
    input  wire                           clk,
    input  wire [csp_pkg::PROGRAM_W-1:0]  fetch_address,   // into the slice's register this clock
    input  wire                           buffer_load,     // the buffer takes the block's word
    output logic [8:0]                    fetch_data       // the slice's part of the fetch buffer
);

`ifdef SYNTHESIS
    `define CSP_SLICE_PRIMITIVE
`elsif SIM_GOWIN_PRIM
    `define CSP_SLICE_PRIMITIVE
`endif
    localparam int ADDRESS_W  = csp_pkg::PROGRAM_W;
    // The slice's flip-flops: the address register, then the buffer's nine.
    // Flop n goes to tile n / 6, slot n % 6; tile t is column t % 3, row t / 3.
    localparam int BUFFER_LOW = ADDRESS_W;
    localparam int FLOPS      = ADDRESS_W + 9;
    localparam bit PLACED     = SITE_X >= 0 && SITE_Y >= 0;
    localparam     SITE       = $sformatf("X%0dY%0d/BSRAM", SITE_X, SITE_Y);

    function automatic int tile_x(input int t);
        tile_x = PLACED ? SITE_X + t % 3 : -1;
    endfunction
    function automatic int tile_y(input int t);
        tile_y = !PLACED ? -1 : t / 3 == 0 ? SITE_Y - 1 : SITE_Y + 1;
    endfunction

    logic [ADDRESS_W-1:0] address_q;    // on the address pin
    logic [17:0]          block_out;    // the block's output register (nine bits used)

`ifdef CSP_SLICE_PRIMITIVE
    for (genvar n = 0; n < FLOPS; n++) begin : g_flop
        localparam int X = tile_x(n / 6);
        localparam int Y = tile_y(n / 6);
        if (n < BUFFER_LOW) begin : g_address
            csp_placed_dff #(.TILE_X(X), .TILE_Y(Y), .SLOT(n % 6)) u_flop (
                .clk          (clk),
                .clock_enable (1'b1),
                .clear        (1'b0),
                .park         (1'b0),
                .d            (fetch_address[n]),
                .q            (address_q[n])
            );
        end else begin : g_buffer
            csp_placed_dff #(.TILE_X(X), .TILE_Y(Y), .SLOT(n % 6), .HOLDS(1'b1)) u_flop (
                .clk          (clk),
                .clock_enable (buffer_load),
                .clear        (1'b0),
                .park         (1'b0),
                .d            (block_out[n - BUFFER_LOW]),
                .q            (fetch_data[n - BUFFER_LOW])
            );
        end
    end

    // A 9-bit word's address is bits [13:3]; the low bits are unused. The
    // block's data pins are 18 wide; the nine of this slice are the low
    // ones. Instantiated twice over, with the site attribute and without
    // (the placer refuses one naming no site).
    if (PLACED) begin : g_site
        (* BEL = SITE *)
        DPX9B #(
            .READ_MODE0  (1'b0),         // bypass: the output register only
            .READ_MODE1  (1'b0),
            .WRITE_MODE0 (2'b00),        // normal
            .WRITE_MODE1 (2'b00),
            .BIT_WIDTH_0 (9),
            .BIT_WIDTH_1 (9),
            .BLK_SEL_0   (3'b000),
            .BLK_SEL_1   (3'b000),
            .RESET_MODE  ("SYNC")
        ) u_block (
            .CLKA    (sclk),
            .CLKB    (clk),
            .CEA     (1'b1),
            .CEB     (1'b1),
            .OCEA    (1'b1),
            .OCEB    (1'b1),
            .RESETA  (1'b0),
            .RESETB  (1'b0),
            .BLKSELA (3'b000),
            .BLKSELB (3'b000),
            .WREA    (write_enable),
            .WREB    (1'b0),
            .ADA     ({write_address, 3'b000}),
            .ADB     ({address_q, 3'b000}),
            .DIA     ({9'd0, write_data}),
            .DIB     (18'd0),
            .DOA     (),
            .DOB     (block_out)
        );
    end else begin : g_free
        DPX9B #(
            .READ_MODE0  (1'b0),
            .READ_MODE1  (1'b0),
            .WRITE_MODE0 (2'b00),
            .WRITE_MODE1 (2'b00),
            .BIT_WIDTH_0 (9),
            .BIT_WIDTH_1 (9),
            .BLK_SEL_0   (3'b000),
            .BLK_SEL_1   (3'b000),
            .RESET_MODE  ("SYNC")
        ) u_block (
            .CLKA    (sclk),
            .CLKB    (clk),
            .CEA     (1'b1),
            .CEB     (1'b1),
            .OCEA    (1'b1),
            .OCEB    (1'b1),
            .RESETA  (1'b0),
            .RESETB  (1'b0),
            .BLKSELA (3'b000),
            .BLKSELB (3'b000),
            .WREA    (write_enable),
            .WREB    (1'b0),
            .ADA     ({write_address, 3'b000}),
            .ADB     ({address_q, 3'b000}),
            .DIA     ({9'd0, write_data}),
            .DIB     (18'd0),
            .DOA     (),
            .DOB     (block_out)
        );
    end
`else
    // The block and the slice's registers as the benches without the
    // vendor's model see them.
    logic [8:0] words [2048];
    initial begin
        for (int address = 0; address < 2048; address++) begin
            words[address] = '0;    // all-zero words are NOPs
        end
        address_q  = '0;
        block_out  = '0;
        fetch_data = '0;
    end
    always_ff @(posedge sclk) begin
        if (write_enable) begin
            words[write_address] <= write_data;
        end
    end
    always_ff @(posedge clk) begin
        address_q <= fetch_address;
        block_out <= {9'd0, words[address_q]};
        if (buffer_load) begin
            fetch_data <= block_out[8:0];
        end
    end
`endif

endmodule
`default_nettype wire
