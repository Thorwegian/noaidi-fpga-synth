//------------------------------------------------------------------------
// csp_sink_area.sv — what the CSP publishes: the sinks the partials read
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// docs/csp_isa.md sections 5 and 6: 1024 words of 18 bits in two pages,
// ping-pong paged. The CSP writes the shadow page while the partial
// pipeline reads the active one, and the pages flip at the end of a pass,
// so the partials always see one complete pass. A pointer names a word and
// the hardware supplies the page: the partials never know which is which.
//
// The partial pipeline reads six words a cycle (a voice word and a channel
// word for each of pitch and cutoff, and so on over two cycles), so the
// area has six read ports. A BSRAM is dual-ported: port B reads, port A
// takes the CSP's write, each page's block through its own; a replica of
// the two blocks gives one read port, six replicas the six, twelve blocks
// in all; every replica takes every write.
//
// Yosys does not infer a block with two read ports (it duplicates the
// memory, and gives a true dual-port RAM to fabric flip-flops), so the
// block is instantiated by hand, as the multiply-add unit's DSP is: a
// DPX9B, 1024 × 18, bypass reads (the word comes out a clock after its
// address). Port A only writes, port B only reads: nothing but a register
// on any of the write pins (the place-and-route tool times no path into a
// block RAM's pins, docs/csp_isa.md section 12: with port A shared
// between the write and a read, a mux of the two addresses sat on the
// pin, and the write's decode on the write-enable pin). Each replica
// keeps the write in a register of its own, next to its blocks, for a
// clock, so the write lands in the blocks a clock after it is given; the
// core's windows allow for it.
//
// A firmware write (a channel setting that only a MIDI message moves)
// goes to both pages, `write_both`: the CSP's write window applies it
// while the partial pipeline is idle, and the word then survives the
// flip. The CSP's own results go to the shadow page only.
//------------------------------------------------------------------------
`default_nettype none
module csp_sink_area #(
    parameter int READ_PORTS = 6              // one a replica
) (
    input  wire                                     clk,
    input  wire                                     reset_n,

    // the CSP's write port
    input  wire                                     write_enable,
    input  wire                                     write_both,        // both pages (firmware)
    input  wire [9:0]                               write_address,
    input  wire [csp_pkg::WORD_W-1:0]               write_data,
    input  wire                                     pass_done,         // one clock: flip the pages

    // the partial pipeline's read ports
    input  wire [READ_PORTS-1:0][9:0]               read_address,
    output logic [READ_PORTS-1:0][csp_pkg::WORD_W-1:0] read_data
);

    localparam int REPLICAS = READ_PORTS;

    logic active_page;          // the page the partials read
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            active_page <= 1'b0;
        end else if (pass_done) begin
            active_page <= !active_page;
        end
    end

    // The page a read was made from, aligned with its data: a flip between
    // the address and the data must not change which page answers.
    logic read_page;
    always_ff @(posedge clk) begin
        read_page <= active_page;
    end

    // The block's data input takes the byte enables in the address's low
    // bits: both halves of the 18-bit word.
    localparam logic [3:0] WRITE_BOTH_HALVES = 4'b0011;

    for (genvar replica = 0; replica < REPLICAS; replica++) begin : g_replica
        // This replica's write register: which page's block takes the
        // write (the shadow page's, or both when the firmware writes; the
        // page as it was when the write was given), the address, the word.
        // No reset: a write given while the chip is in reset still lands
        // (the benches load the sinks that way); the write flags start
        // clear instead. `keep`, or yosys merges the replicas' identical
        // registers into one that fans out to twelve blocks' pins across
        // the chip.
        logic [1:0]                 written_q = '0;
        logic [9:0]                 address_q;
        logic [csp_pkg::WORD_W-1:0] data_q;
        (* keep *) always_ff @(posedge clk) begin
            for (int page = 0; page < 2; page++) begin
                written_q[page] <= write_enable && (write_both || page == int'(!active_page));
            end
        end
        (* keep *) always_ff @(posedge clk) begin
            address_q <= write_address;
            data_q    <= write_data;
        end

        // each block's output, the page-1 block's above the page-0's (a
        // flat vector: yosys takes an unpacked array for a memory)
        logic [2 * csp_pkg::WORD_W-1:0] block_data;

        for (genvar page = 0; page < 2; page++) begin : g_page
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
                .WREA    (written_q[page]),
                .WREB    (1'b0),
                .ADA     ({address_q, WRITE_BOTH_HALVES}),
                .ADB     ({read_address[replica], 4'b0000}),
                .DIA     (data_q),
                .DIB     (18'd0),
                .DOA     (),
                .DOB     (block_data[page * csp_pkg::WORD_W +: csp_pkg::WORD_W])
            );
        end

        // The page a read was made from answers it.
        assign read_data[replica] = read_page ? block_data[csp_pkg::WORD_W +: csp_pkg::WORD_W]
                                            : block_data[0 +: csp_pkg::WORD_W];
    end

`ifdef SIM_GOWIN_PRIM
    // The benches read the sinks through this copy: the blocks' contents
    // are bits in the vendor's model. Simulation only.
    logic [csp_pkg::WORD_W-1:0] page_words [2][1024];
    initial begin
        for (int page = 0; page < 2; page++) begin
            for (int word = 0; word < 1024; word++) begin
                page_words[page][word] = '0;
            end
        end
    end
    always_ff @(posedge clk) begin
        if (g_replica[0].written_q[0]) begin
            page_words[0][g_replica[0].address_q] <= g_replica[0].data_q;
        end
        if (g_replica[0].written_q[1]) begin
            page_words[1][g_replica[0].address_q] <= g_replica[0].data_q;
        end
    end
`endif

endmodule
`default_nettype wire
