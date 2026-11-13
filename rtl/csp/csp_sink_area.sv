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
// over two cycles), so the area has six read ports. A block (DPX9B) reads
// on both its ports, so a pair of blocks, one a page, is two read ports:
// port A of each block serves an even read port, port B the odd one above
// it, and the page a read was made from selects which block's word is
// answered. Three pairs are the six ports, six blocks in all (#358; it was
// a pair per port, twelve blocks, port A only ever writing).
//
// A write takes port A of the block it lands in for one clock, in place
// of that port's read. The core's words go to the shadow page, whose block
// nobody listens to, so they land at any time. The firmware's words
// (through the pass's window, write_both) go to both pages, so that a flip
// keeps them — a channel setting only a MIDI message moves — and take the
// active page's port A as well: the window lies in the slots after the
// last partial's read (csp_pkg::WINDOW_START is in the pass's last sample,
// past the issue slots), where the pipeline parks its ports on
// POINTER_ZERO. The behavioural model counts a write that takes a port
// whose address was not the parked one (read_taken_violations, which the
// benches hold at zero).
//
// Each block keeps the write in a register of its own beside it for a
// clock (`keep`, or yosys merges the copies into one register fanning out
// to six blocks' pins across the chip; a register for two blocks is a
// route the tool does not time, #238): a register and the port's mux in
// front of a block's pin, as the pipeline's pointer mux is on the read
// pins (rule 1), and the write lands a clock after the core gives it,
// long before the pass ends.
//
// The two ports meet on a row only when a port B reads, in the clock port A
// writes it: the block keeps the write and that read's word is invalid
// (UG285-1.09E section 6.3, both ports on one clock). On the shadow block
// the word is discarded; on the active block the ports are parked on the
// row nothing writes. The word POINTER_ZERO (1023) is never written and
// reads zero.
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
    localparam int PAIRS = READ_PORTS / 2;    // a pair of blocks serves two read ports

    if (READ_PORTS % 2 != 0) $error("csp_sink_area: READ_PORTS must be even, a pair of blocks serves two");

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
    for (genvar pair = 0; pair < PAIRS; pair++) begin : g_pair
        // this pair's write enables: which page's block takes the write (the shadow page's,
        // as it was when the write was given)
        logic [1:0]                      written_q;
        (* keep *) always_ff @(posedge clk or negedge reset_n) begin
            if (!reset_n) written_q <= '0;
            else          written_q <= {write_enable && (write_both || active_page == 1'b0), write_enable && (write_both || active_page == 1'b1)};
        end

        // each port's word from the two blocks, page 1's above page 0's: a flat vector, since
        // yosys takes an unpacked array for a memory and the blocks' outputs for its conflicting
        // writers
        logic [2 * csp_pkg::WORD_W-1:0] port_a_data, port_b_data;
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
            // lane enables, both on (csp_dmem.sv does the same). Port A is the even read
            // port's, except in the clock a write lands in this block.
            wire [13:0] port_a_address = written_q[page] ? {address_q, 4'b0011}
                                                         : {read_address[2 * pair], 4'b0000};
            DPX9B #(
                .READ_MODE0 (1'b0), .READ_MODE1 (1'b0), .WRITE_MODE0 (2'b00), .WRITE_MODE1 (2'b00),
                .BIT_WIDTH_0 (18), .BIT_WIDTH_1 (18), .BLK_SEL_0 (3'b000), .BLK_SEL_1 (3'b000),
                .RESET_MODE ("SYNC")
            ) u_block (
                .CLKA (clk), .CLKB (clk), .CEA (1'b1), .CEB (1'b1), .OCEA (1'b1), .OCEB (1'b1),
                .RESETA (1'b0), .RESETB (1'b0), .BLKSELA (3'b000), .BLKSELB (3'b000),
                .WREA (written_q[page]), .WREB (1'b0),
                .ADA (port_a_address), .ADB ({read_address[2 * pair + 1], 4'b0000}),
                .DIA (data_q), .DIB (18'd0),
                .DOA (port_a_data[page * csp_pkg::WORD_W +: csp_pkg::WORD_W]),
                .DOB (port_b_data[page * csp_pkg::WORD_W +: csp_pkg::WORD_W])
            );
        end
        assign read_data[2 * pair]     = read_page ? port_a_data[csp_pkg::WORD_W +: csp_pkg::WORD_W] : port_a_data[0 +: csp_pkg::WORD_W];
        assign read_data[2 * pair + 1] = read_page ? port_b_data[csp_pkg::WORD_W +: csp_pkg::WORD_W] : port_b_data[0 +: csp_pkg::WORD_W];
    end
`else
    // the behavioural pages, one write register as a pair's, every port served from them
    logic                            written_q [2];
    logic [csp_pkg::SINK_WORD_W-1:0] address_q;
    logic [csp_pkg::WORD_W-1:0]      data_q;
    logic [csp_pkg::WORD_W-1:0]      pages [2][WORDS];
    logic [csp_pkg::WORD_W-1:0]      page_word [READ_PORTS][2];
    // the clocks in which a write took an even port of the page the partials read while that
    // port's address was not the parked word: the pipeline wanted the word the write displaced
    int unsigned                     read_taken_violations;
    initial begin
        written_q[0] = 1'b0;
        written_q[1] = 1'b0;
        read_taken_violations = 0;
        for (int page = 0; page < 2; page++) for (int word = 0; word < WORDS; word++) pages[page][word] = '0;
    end
    always_ff @(posedge clk) begin
        written_q[0] <= write_enable && (write_both || active_page == 1'b1);
        written_q[1] <= write_enable && (write_both || active_page == 1'b0);
        address_q    <= write_address;
        data_q       <= write_data;
        for (int page = 0; page < 2; page++) begin
            if (written_q[page]) pages[page][address_q] <= data_q;
            for (int port = 0; port < READ_PORTS; port++) begin
                // the write takes the block's port A, the even port's: that port's word holds
                // through the write's clock (normal write mode, UG285-1.09E section 6.2.1)
                if (!(written_q[page] && port % 2 == 0)) begin
                    page_word[port][page] <= pages[page][read_address[port]];
                end else if (page == int'(active_page) && read_address[port] != synth_pkg::POINTER_ZERO) begin
                    read_taken_violations <= read_taken_violations + 1;
                end
            end
        end
    end
    always_comb begin
        for (int port = 0; port < READ_PORTS; port++) read_data[port] = read_page ? page_word[port][1] : page_word[port][0];
    end
`endif

endmodule
`default_nettype wire
