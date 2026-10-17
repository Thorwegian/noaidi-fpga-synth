//------------------------------------------------------------------------
// csp_bank.sv — one bank of the register file: a block RAM at a chosen site,
//               with the registers on its pins placed beside it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// 1024 words of 18 bits in one DPX9B, written through port A and read
// through port B (bypass mode: the word is in the block's own output
// register a clock after its address, and nowhere else: docs/csp_isa.md
// section 12). The block is instantiated by hand so that it can carry a
// placement: the tool does not time the paths into or out of a block
// RAM's pins, and left to itself it put the register file's banks in a
// far corner of the chip, up to fifty tiles from the registers that drive
// their pins — a route of the order of the clock period at 73.728 MHz
// (docs/gowin_oss_notes.md). SITE_X, SITE_Y name the BSRAM site the block
// goes to (13, 27: "X13Y27/BSRAM"); negative leaves the choice to the
// placer, and the registers with it.
//
// Every register on the block's pins is the bank's own and placed too,
// flip-flop by flip-flop with the LUT in front of it (csp_placed_dff.sv),
// on the fabric tiles of the block's three columns (a block spans three)
// in the rows above and below it, nearest first (Y−1, Y+1, Y−2, Y+2), six
// to a tile:
//
//   - the write register: the enable, the index and the word go in a clock
//     before the block takes them (29 flip-flops). Left to the placer, this
//     register went with the logic that feeds it, 30–44 tiles away, and on
//     the board at 73.728 MHz a store after idle cycles landed with an
//     address bit still at its old value (issue #222, the five-word test);
//   - the read address (ADDRESS_REGISTER): the index goes into a register
//     on the pin, held while read_hold, and the block reads it the clock
//     after (10 flip-flops). With the core's own address register 13–33
//     tiles away, a read right after idle cycles returned register 0's
//     word: the pins still showed the bubble's address when the block
//     sampled them. While read_park the register holds PARK_INDEX, a row
//     nothing writes: a block reads the row on its address pins on every
//     clock, idle or not, and on the board a row read on port B in the
//     clock port A wrote it lost the write (issue #222: the rows the ports
//     were left on after the last instruction were the boot image's lost
//     words, the constant ONE among them, on a placement that had every
//     register in place — and no such loss with the ports parked);
//   - the output (OUTPUT_REGISTER): the block's output register is taken
//     into a register of the bank's, which is what the core's E1 holds
//     (18 flip-flops); the mirror image of the address path.
//
// With both off, the index is on the pin as given and the word comes
// straight from the block's output register (the sink area's banks, whose
// own registers stand in).
//------------------------------------------------------------------------
`default_nettype none
module csp_bank #(
    parameter int SITE_X           = -1,             // the BSRAM site's column, or negative
    parameter int SITE_Y           = -1,             // and row
    parameter bit ADDRESS_REGISTER = 1'b0,           // the read index through a register of the bank's
    parameter bit OUTPUT_REGISTER  = 1'b0,           // the word through a register of the bank's
    parameter logic [9:0] PARK_INDEX = 10'd0         // the row the address register holds while read_park
) (
    input  wire                        clk,
    // the write, as decoded (which bank, the index, the word); taken into
    // the bank's own register this clock, into the block the next
    input  wire                        write_enable,
    input  wire [9:0]                  write_index,
    input  wire [csp_pkg::WORD_W-1:0]  write_data,
    // the read: the index on the pin, or into the bank's register (held
    // while read_hold); the word a clock after the pin's address, or a
    // clock after that from the bank's register
    input  wire [9:0]                  read_index,
    input  wire                        read_hold,
    input  wire                        read_park,    // no instruction reads: the register takes PARK_INDEX (unless read_hold)
    output logic [csp_pkg::WORD_W-1:0] read_data
);

`ifdef SYNTHESIS
    `define CSP_BANK_PRIMITIVE
`elsif SIM_GOWIN_PRIM
    `define CSP_BANK_PRIMITIVE
`endif
    localparam int WORD_W      = csp_pkg::WORD_W;
    // The bank's flip-flops, in order: the write register (bit k of {word,
    // index, enable}), the address register, the output register. Flop n
    // goes to tile n / 6, slot n % 6; tile t is column t % 3, row t / 3.
    localparam int WRITE_BITS  = WORD_W + 10 + 1;
    localparam int ADDRESS_LOW = WRITE_BITS;
    localparam int OUTPUT_LOW  = WRITE_BITS + 10;
    localparam int FLOPS       = WRITE_BITS + 10 + WORD_W;
    localparam bit PLACED      = SITE_X >= 0 && SITE_Y >= 0;
    localparam     SITE        = $sformatf("X%0dY%0d/BSRAM", SITE_X, SITE_Y);

    function automatic int tile_x(input int t);
        tile_x = PLACED ? SITE_X + t % 3 : -1;
    endfunction
    function automatic int tile_y(input int t);
        tile_y = !PLACED ? -1
               : t / 3 == 0 ? SITE_Y - 1 : t / 3 == 1 ? SITE_Y + 1 : t / 3 == 2 ? SITE_Y - 2 : SITE_Y + 2;
    endfunction

    wire  [WRITE_BITS-1:0] write_in = {write_data, write_index, write_enable};
    logic [WRITE_BITS-1:0] write_q;
    wire                   enable_q = write_q[0];
    wire [9:0]             index_q  = write_q[10:1];
    wire [WORD_W-1:0]      data_q   = write_q[WRITE_BITS-1:11];
    logic [9:0]            address_q;    // the register on the read pin, when ADDRESS_REGISTER
    wire  [9:0]            pin_index = ADDRESS_REGISTER ? address_q : read_index;
    logic [WORD_W-1:0]     block_out;    // the block's output register
    logic [WORD_W-1:0]     output_q;     // the bank's, when OUTPUT_REGISTER
    assign read_data = OUTPUT_REGISTER ? output_q : block_out;

`ifdef CSP_BANK_PRIMITIVE
    for (genvar n = 0; n < FLOPS; n++) begin : g_flop
        localparam int X = tile_x(n / 6);
        localparam int Y = tile_y(n / 6);
        if (n < ADDRESS_LOW) begin : g_write
            csp_placed_dff #(.TILE_X(X), .TILE_Y(Y), .SLOT(n % 6)) u_flop (
                .clk          (clk),
                .clock_enable (1'b1),
                .clear        (1'b0),
                .park         (1'b0),
                .d            (write_in[n]),
                .q            (write_q[n])
            );
        end else if (n < OUTPUT_LOW) begin : g_address
            if (ADDRESS_REGISTER) begin : g_placed
                csp_placed_dff #(.TILE_X(X), .TILE_Y(Y), .SLOT(n % 6), .HOLDS(1'b1),
                                 .PARKS(1'b1), .PARK_VALUE(PARK_INDEX[n - ADDRESS_LOW])) u_flop (
                    .clk          (clk),
                    .clock_enable (!read_hold),
                    .clear        (1'b0),
                    .park         (read_park),
                    .d            (read_index[n - ADDRESS_LOW]),
                    .q            (address_q[n - ADDRESS_LOW])
                );
            end
        end else begin : g_output
            if (OUTPUT_REGISTER) begin : g_placed
                csp_placed_dff #(.TILE_X(X), .TILE_Y(Y), .SLOT(n % 6)) u_flop (
                    .clk          (clk),
                    .clock_enable (1'b1),
                    .clear        (1'b0),
                    .park         (1'b0),
                    .d            (block_out[n - OUTPUT_LOW]),
                    .q            (output_q[n - OUTPUT_LOW])
                );
            end
        end
    end

    // The address of an 18-bit word is bits [13:4]; on the write side the
    // low bits are the byte enables, both halves of the word. The site
    // attribute is a string even when unplaced; the placer ignores one
    // naming no site ("X-1Y-1/BSRAM" is refused), so the block is
    // instantiated twice over, with and without it.
    if (PLACED) begin : g_site
        (* BEL = SITE *)
        DPX9B #(
            .READ_MODE0  (1'b0),         // bypass: the output register only
            .READ_MODE1  (1'b0),
            .WRITE_MODE0 (2'b00),        // normal
            .WRITE_MODE1 (2'b00),
            .BIT_WIDTH_0 (18),
            .BIT_WIDTH_1 (18),
            .BLK_SEL_0   (3'b000),
            .BLK_SEL_1   (3'b000),
            .RESET_MODE  ("SYNC")
        ) u_block (
            .CLKA    (clk),
            .CLKB    (clk),
            .CEA     (1'b1),
            .CEB     (1'b1),
            .OCEA    (1'b1),
            .OCEB    (1'b1),
            .RESETA  (1'b0),
            .RESETB  (1'b0),
            .BLKSELA (3'b000),
            .BLKSELB (3'b000),
            .WREA    (enable_q),
            .WREB    (1'b0),
            .ADA     ({index_q, 4'b0011}),
            .ADB     ({pin_index, 4'b0000}),
            .DIA     (data_q),
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
            .BIT_WIDTH_0 (18),
            .BIT_WIDTH_1 (18),
            .BLK_SEL_0   (3'b000),
            .BLK_SEL_1   (3'b000),
            .RESET_MODE  ("SYNC")
        ) u_block (
            .CLKA    (clk),
            .CLKB    (clk),
            .CEA     (1'b1),
            .CEB     (1'b1),
            .OCEA    (1'b1),
            .OCEB    (1'b1),
            .RESETA  (1'b0),
            .RESETB  (1'b0),
            .BLKSELA (3'b000),
            .BLKSELB (3'b000),
            .WREA    (enable_q),
            .WREB    (1'b0),
            .ADA     ({index_q, 4'b0011}),
            .ADB     ({pin_index, 4'b0000}),
            .DIA     (data_q),
            .DIB     (18'd0),
            .DOA     (),
            .DOB     (block_out)
        );
    end
`endif

`ifndef CSP_BANK_PRIMITIVE
    // The bank's registers as the benches without the vendor's model see them.
    initial begin
        write_q   = '0;
        address_q = '0;
        output_q  = '0;
    end
    always_ff @(posedge clk) begin
        write_q <= write_in;
        if (!read_hold) begin
            address_q <= read_park ? PARK_INDEX : read_index;
        end
        output_q <= block_out;
    end
`endif

`ifndef SYNTHESIS
    // The words as the benches see them (`words`): the model of the block
    // without the vendor's model, and a shadow of it with (the benches
    // read registers through this copy; a read of the word being written
    // returns the old word, as the block does).
    logic [WORD_W-1:0] words [1024];
    initial begin
        for (int index = 0; index < 1024; index++) begin
            words[index] = '0;
        end
    end
    always_ff @(posedge clk) begin
        if (enable_q) begin
            words[index_q] <= data_q;
        end
    end
`ifndef CSP_BANK_PRIMITIVE
    always_ff @(posedge clk) begin
        block_out <= words[pin_index];
    end
`endif
`endif

endmodule
`default_nettype wire
