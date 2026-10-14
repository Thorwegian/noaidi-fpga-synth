//------------------------------------------------------------------------
// csp_fit.sv — the new CSP alone on the chip, for size and timing
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Not part of the synth: a top level that places and routes the new CSP
// (rtl/csp) on its own, to measure its BSRAM, DSP and logic and its
// timing at the system clock before it replaces dsp/csp.sv (#220, #222).
// `make csp-fit` builds it.
//
// Every input the CSP takes from SPI is shifted in from one pin, so
// nothing is constant and nothing can be optimised away; every sink
// write is folded into one output pin. The system clock is taken
// straight from a pin and constrained to 73.728 MHz: this is a timing
// check, not a bitstream to run.
//------------------------------------------------------------------------
`default_nettype none
module csp_fit (
    input  wire clk,           // constrained to 73.728 MHz
    input  wire sclk,          // the SPI clock
    input  wire spi_mosi,      // everything the SPI side writes, serially
    input  wire spi_cs_n,      // a word is complete on its rising edge
    output logic folded        // every sink write, XOR-folded
);

    // ---- the SPI side: a 64-bit shift register fills every port ----------------
    logic [63:0] shift;
    logic        cs_seen, word_done;
    always_ff @(posedge sclk) begin
        shift     <= {shift[62:0], spi_mosi};
        cs_seen   <= spi_cs_n;
        word_done <= spi_cs_n && !cs_seen;
    end

    wire                                 held          = shift[63];
    wire                                 imem_write    = word_done && shift[62];
    wire                                 queue_write   = word_done && shift[61];
    wire                                 swap          = word_done && shift[60];
    wire [csp_pkg::PROGRAM_W-1:0]        imem_address  = shift[58:48];
    wire [35:0]                          imem_data     = shift[35:0];
    wire [csp_pkg::REGISTER_W-1:0]       queue_address = shift[46:36];
    wire [csp_pkg::WORD_W-1:0]           queue_data    = shift[17:0];

    // ---- reset and the pass tick (every 1536 system clocks) ----------------------
    // A registered reset, as the synth's reset synchroniser gives one.
    logic [3:0]  reset_count = '0;
    logic        reset_n     = 1'b0;
    always_ff @(posedge clk) begin
        if (reset_count != 4'hf) reset_count <= reset_count + 1'b1;
        reset_n <= reset_count == 4'hf;
    end

    logic [10:0] pass_counter;
    wire         pass_start = pass_counter == '0;
    always_ff @(posedge clk) begin
        pass_counter <= (pass_counter == 11'(csp_pkg::CYCLES_PER_PASS - 1)) ? '0 : pass_counter + 1'b1;
    end

    logic held_meta, held_sync;
    always_ff @(posedge clk) begin
        held_meta <= held;
        held_sync <= held_meta;
    end

    // ---- the CSP ---------------------------------------------------------------------
    logic [csp_pkg::PROGRAM_W-1:0]  fetch_address;
    logic [35:0]                    fetch_data;
    logic                           queue_pop, queue_committed, queue_full;
    logic [csp_pkg::REGISTER_W-1:0] head_address;
    logic [csp_pkg::WORD_W-1:0]     head_data;
    logic                           sink_write_enable, pass_done;
    logic [9:0]                     sink_write_address;
    logic [csp_pkg::WORD_W-1:0]     sink_write_data;

    csp_instruction_memory u_instruction_memory (
        .sclk (sclk), .held (held), .write_enable (imem_write),
        .write_address (imem_address), .write_data (imem_data),
        .clk (clk), .fetch_address (fetch_address), .fetch_data (fetch_data)
    );

    csp_write_queue u_write_queue (
        .sclk (sclk), .sclk_reset_n (reset_n), .write_enable (queue_write),
        .write_address (queue_address), .write_data (queue_data), .swap (swap),
        .full (queue_full), .clk (clk), .reset_n (reset_n), .pop (queue_pop),
        .committed (queue_committed), .head_address (head_address), .head_data (head_data)
    );

    csp_core u_core (
        .clk (clk), .reset_n (reset_n), .pass_start (pass_start), .held (held_sync),
        .fetch_address (fetch_address), .fetch_data (fetch_data),
        .queue_pop (queue_pop), .queue_committed (queue_committed),
        .queue_address (head_address), .queue_data (head_data),
        .sink_write_enable (sink_write_enable), .sink_write_address (sink_write_address),
        .sink_write_data (sink_write_data), .pass_done (pass_done)
    );

    // ---- every sink write, folded into one pin -----------------------------------------
    always_ff @(posedge clk) begin
        if (sink_write_enable) begin
            folded <= ^{folded, sink_write_address, sink_write_data, pass_done, queue_full};
        end
    end

endmodule
`default_nettype wire
