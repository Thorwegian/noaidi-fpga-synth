//------------------------------------------------------------------------
// csp_sink_area.sv — what the CSP publishes: the sinks the partials read
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// docs/csp2_architecture.md section 2 and 5: 1024 words of 18 bits in two
// pages. The core writes the shadow page through its sink write pins (the
// registers of its W stage) while the partial pipeline reads the active
// one, and the pages flip when a pass starts, so the partials always see
// one complete pass — the pass the core just finished. A pointer names a
// word and the hardware supplies the page: the partials never know which
// is which. The co-simulation's bench and the model keep the same two
// pages and flip them the same way.
//
// The partial pipeline reads six words a cycle (a partial's ten pointers
// over two cycles), so the area has six read ports. A block is
// dual-ported: port B reads, port A takes the write, each page's block
// through its own; a replica of the two blocks is one read port, six
// replicas the six, twelve blocks in all, and every replica takes every
// write. Each block keeps the write in a register of its own beside it
// for a clock (`keep`, or yosys merges the copies into one register
// fanning out to twelve blocks' pins across the chip; a register for two
// blocks is a route the tool does not time, #238): nothing but a register
// in front of a block's pin (rule 1), and the write lands a clock after
// the core gives it, long before the pass ends.
//
// The core's words go to the shadow page; the firmware's (through the
// pass's window, write_both) to both pages, so that a flip keeps them: a
// channel setting only a MIDI message moves. The two ports never meet on a
// row (UG285-1.4E p6, note 1) for the core's words; a firmware word lands
// in the window, when the partials are reading whatever row their pointers
// name — one row of one block, at most once a pass, the same word both times.
// The word POINTER_ZERO (1023) is never written and reads zero.
//------------------------------------------------------------------------
`default_nettype none
module csp_sink_area #(
    parameter int READ_PORTS = synth_pkg::SINK_READ_PORTS
) (
    input  wire                                     clk,
    input  wire                                     reset_n,

    // the core's sink write, its W stage's registers
    input  wire                                     write_enable,
    input  wire                                     write_both,        // the firmware's word: both pages, so the flip keeps it
    input  wire [csp_pkg::SINK_WORD_W-1:0]          write_address,
    input  wire [csp_pkg::WORD_W-1:0]               write_data,
    input  wire                                     pass_start,        // the pages flip

    // the partial pipeline's read ports: the word the clock after its address
    input  wire [READ_PORTS-1:0][csp_pkg::SINK_WORD_W-1:0]  read_address,
    output logic [READ_PORTS-1:0][csp_pkg::WORD_W-1:0]      read_data
);

    localparam int WORDS = csp_pkg::SINK_COUNT;

    logic active_page;          // the page the partials read; the core writes the other
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)        active_page <= 1'b0;
        else if (pass_start) active_page <= !active_page;
    end

    // the page a read was made from, aligned with its data: a flip between the address and
    // the data must not change which page answers
    logic read_page;
    always_ff @(posedge clk) read_page <= active_page;

`ifdef SYNTHESIS
    for (genvar replica = 0; replica < READ_PORTS; replica++) begin : g_replica
        // this replica's write enables: which page's block takes the write (the shadow page's,
        // as it was when the write was given)
        logic [1:0]                      written_q;
        (* keep *) always_ff @(posedge clk or negedge reset_n) begin
            if (!reset_n) written_q <= '0;
            else          written_q <= {write_enable && (write_both || active_page == 1'b0), write_enable && (write_both || active_page == 1'b1)};
        end

        // each block's output, page 1's above page 0's: a flat vector, since yosys takes an
        // unpacked array for a memory and the blocks' outputs for its conflicting writers
        logic [2 * csp_pkg::WORD_W-1:0] block_data;
        for (genvar page = 0; page < 2; page++) begin : g_page
            // this block's write register, the address and the word: the pins' own (one register
            // for two blocks is a route the tool does not time, #238)
            logic [csp_pkg::SINK_WORD_W-1:0] address_q;
            logic [csp_pkg::WORD_W-1:0]      data_q;
            (* keep *) always_ff @(posedge clk) begin   // the keep on the process: yosys merges kept signals
                address_q <= write_address;
                data_q    <= write_data;
            end
            // An 18-bit word's address is AD[13:4]; the low two bits of ADA are the write's
            // lane enables, both on (csp_dmem.sv does the same)
            DPX9B #(
                .READ_MODE0 (1'b0), .READ_MODE1 (1'b0), .WRITE_MODE0 (2'b00), .WRITE_MODE1 (2'b00),
                .BIT_WIDTH_0 (18), .BIT_WIDTH_1 (18), .BLK_SEL_0 (3'b000), .BLK_SEL_1 (3'b000),
                .RESET_MODE ("SYNC")
            ) u_block (
                .CLKA (clk), .CLKB (clk), .CEA (1'b1), .CEB (1'b1), .OCEA (1'b1), .OCEB (1'b1),
                .RESETA (1'b0), .RESETB (1'b0), .BLKSELA (3'b000), .BLKSELB (3'b000),
                .WREA (written_q[page]), .WREB (1'b0),
                .ADA ({address_q, 4'b0011}), .ADB ({read_address[replica], 4'b0000}),
                .DIA (data_q), .DIB (18'd0), .DOA (), .DOB (block_data[page * csp_pkg::WORD_W +: csp_pkg::WORD_W])
            );
        end
        assign read_data[replica] = read_page ? block_data[csp_pkg::WORD_W +: csp_pkg::WORD_W] : block_data[0 +: csp_pkg::WORD_W];
    end
`else
    // the behavioural pages, one write register as a replica's, every port served from them
    logic                            written_q [2];
    logic [csp_pkg::SINK_WORD_W-1:0] address_q;
    logic [csp_pkg::WORD_W-1:0]      data_q;
    logic [csp_pkg::WORD_W-1:0]      pages [2][WORDS];
    logic [csp_pkg::WORD_W-1:0]      page_word [READ_PORTS][2];
    initial begin
        written_q[0] = 1'b0;
        written_q[1] = 1'b0;
        for (int page = 0; page < 2; page++) for (int word = 0; word < WORDS; word++) pages[page][word] = '0;
    end
    always_ff @(posedge clk) begin
        written_q[0] <= write_enable && (write_both || active_page == 1'b1);
        written_q[1] <= write_enable && (write_both || active_page == 1'b0);
        address_q    <= write_address;
        data_q       <= write_data;
        for (int page = 0; page < 2; page++) begin
            if (written_q[page]) pages[page][address_q] <= data_q;
            for (int port = 0; port < READ_PORTS; port++) page_word[port][page] <= pages[page][read_address[port]];
        end
    end
    always_comb begin
        for (int port = 0; port < READ_PORTS; port++) read_data[port] = read_page ? page_word[port][1] : page_word[port][0];
    end
`endif

endmodule
`default_nettype wire
