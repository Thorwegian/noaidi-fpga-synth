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
// area has six read ports. This toolchain maps one read and one write
// to a BSRAM, so each read port has its own copy of each page: twelve
// blocks of 1024 × 18. Every copy takes every write.
//
// A firmware write (a channel setting that only a MIDI message moves)
// goes to both pages, `write_both`: the CSP's write window applies it
// while the partial pipeline is idle, and the word then survives the
// flip. The CSP's own results go to the shadow page only.
//
// Reads are synchronous: the address goes in on one clock, the word comes
// out on the next.
//------------------------------------------------------------------------
`default_nettype none
module csp_sink_area #(
    parameter int READ_PORTS = 6
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

    for (genvar port = 0; port < READ_PORTS; port++) begin : g_port
        logic [csp_pkg::WORD_W-1:0] page_word [2];

        // Each page's copy is a memory of its own: one write port and one
        // read port, which yosys maps to a BSRAM. (Both pages in one array
        // would be one memory with two write ports.)
        for (genvar page = 0; page < 2; page++) begin : g_page
            logic [csp_pkg::WORD_W-1:0] words [1024];
            initial begin
                for (int word = 0; word < 1024; word++) begin
                    words[word] = '0;
                end
            end

            wire page_written = write_enable && (write_both || page == int'(!active_page));
            always_ff @(posedge clk) begin
                if (page_written) begin
                    words[write_address] <= write_data;
                end
            end
            always_ff @(posedge clk) begin
                page_word[page] <= words[read_address[port]];
            end
        end

        assign read_data[port] = page_word[read_page];
    end

endmodule
`default_nettype wire
