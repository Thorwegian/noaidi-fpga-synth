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
// area has six read ports. A BSRAM is dual-ported: the active page's block
// serves two of the ports (both of its ports read), and the shadow page's
// block takes the CSP's write on one of its own. Three replicas of the two
// blocks give the six ports, six blocks in all; every replica takes every
// write.
//
// Yosys does not infer a block with two read ports (it duplicates the
// memory, and gives a true dual-port RAM to fabric flip-flops), so the
// block is instantiated by hand, as the multiply-add unit's DSP is: a
// DPX9B, 1024 × 18, bypass reads (the word comes out a clock after its
// address). Port A reads or writes by the address mux in front of it; port
// B only reads.
//
// A firmware write (a channel setting that only a MIDI message moves)
// goes to both pages, `write_both`: the CSP's write window applies it
// while the partial pipeline is idle, and the word then survives the
// flip. The active page's block is written through its port A for it. The
// CSP's own results go to the shadow page only.
//------------------------------------------------------------------------
`default_nettype none
module csp_sink_area #(
    parameter int READ_PORTS = 6              // two a replica
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

    localparam int REPLICAS = (READ_PORTS + 1) / 2;

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
        localparam int PORT_A = 2 * replica;
        localparam int PORT_B = 2 * replica + 1;

        // each block's two outputs, the page-1 block's above the page-0's (a
        // flat vector: yosys takes an unpacked array for a memory)
        logic [2 * csp_pkg::WORD_W-1:0] block_a_data;
        logic [2 * csp_pkg::WORD_W-1:0] block_b_data;

        // an odd number of ports leaves the last block's port B unused
        wire [9:0] address_b;
        if (PORT_B < READ_PORTS) begin : g_address_b
            assign address_b = read_address[PORT_B];
        end else begin : g_unused_b
            assign address_b = '0;
        end

        for (genvar page = 0; page < 2; page++) begin : g_page
            // This block takes the write: the shadow page's, or both when
            // the firmware writes.
            wire block_written = write_enable && (write_both || page == int'(!active_page));

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
                .WREA    (block_written),
                .WREB    (1'b0),
                .ADA     (block_written ? {write_address, WRITE_BOTH_HALVES}
                                        : {read_address[PORT_A], 4'b0000}),
                .ADB     ({address_b, 4'b0000}),
                .DIA     (write_data),
                .DIB     (18'd0),
                .DOA     (block_a_data[page * csp_pkg::WORD_W +: csp_pkg::WORD_W]),
                .DOB     (block_b_data[page * csp_pkg::WORD_W +: csp_pkg::WORD_W])
            );
        end

        // The page a read was made from answers it.
        assign read_data[PORT_A] = read_page ? block_a_data[csp_pkg::WORD_W +: csp_pkg::WORD_W]
                                          : block_a_data[0 +: csp_pkg::WORD_W];
        if (PORT_B < READ_PORTS) begin : g_port_b
            assign read_data[PORT_B] = read_page ? block_b_data[csp_pkg::WORD_W +: csp_pkg::WORD_W]
                                              : block_b_data[0 +: csp_pkg::WORD_W];
        end
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
        if (write_enable) begin
            if (write_both || active_page) begin
                page_words[0][write_address] <= write_data;
            end
            if (write_both || !active_page) begin
                page_words[1][write_address] <= write_data;
            end
        end
    end
`endif

endmodule
`default_nettype wire
