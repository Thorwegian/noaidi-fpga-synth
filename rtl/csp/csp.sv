//------------------------------------------------------------------------
// csp.sv — the CSP: the core, DMEM's three read copies and the pass
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// What top.sv and the co-simulation bench instantiate beside IMEM, the
// decode ROM and the write FIFO (which the SPI link loads and reads on its
// own clock): csp_core for the instructions, three copies of DMEM (R, X and
// Y, each taking every write, so an instruction reads three words in a cycle),
// and csp_pass for the cycle count, the firmware's write window and the
// probe. The one write port and the one probe read are shared in time, not
// in space: the core's writes end at cycle 1480 (the last row's A is at most
// 1473, its W seven later) and the window's begin at 1485, and both go
// through the core's own write registers, which take the pass's write when it
// has one; likewise the probe asks for the R copy's read registers at the
// pass's end, while the core is idle. DMEM's pins are all registers.
//------------------------------------------------------------------------
`default_nettype none
module csp (
    input  wire                              clk,
    input  wire                              reset_n,
    input  wire                              pass_start,
    input  wire                              held,

    // IMEM and the decode ROM
    output logic [csp_pkg::PROGRAM_W-1:0]    fetch_address,
    input  wire  [csp_pkg::ROW_W-1:0]        fetch_row,
    output logic [csp_pkg::ROM_ADDRESS_W-1:0] rom_op,
    input  wire  [csp_pkg::ROM_W-1:0]        control_word,

    // the write FIFO's head
    output logic                             fifo_pop,
    input  wire                              fifo_committed,
    input  wire                              fifo_head_valid,
    input  wire  [csp_pkg::DWORD_W-1:0]      fifo_head_dword,

    // the probe
    input  wire  [csp_pkg::REGISTER_W-1:0]   probe_address,
    output logic [csp_pkg::WIDE_W-1:0]       probe_pair,

    output logic [csp_pkg::CYCLE_W-1:0]      cycle,
    output logic [31:0]                      pass_counter,

    // the sink area (#236)
    output logic                             sink_write_enable,
    output logic [csp_pkg::SINK_WORD_W-1:0]  sink_write_address,
    output logic [csp_pkg::WORD_W-1:0]       sink_write_data
);

    // the core's ports: DMEM's pins are the core's registers
    logic [csp_pkg::BANK_INDEX_W-1:0] read_r_even_index, read_r_odd_index, read_x_even_index, read_x_odd_index,
                                      read_y_even_index, read_y_odd_index;
    logic [csp_pkg::WIDE_W-1:0]       read_r_pair, read_x_pair, read_y_pair;
    logic                             write_even_enable, write_odd_enable;
    logic [csp_pkg::BANK_INDEX_W-1:0] write_index;
    logic [csp_pkg::WORD_W-1:0]       write_even_data, write_odd_data;

    // the pass: the window's writes, the counter's, and the probe's request
    logic                             pass_write_enable, probe_request;
    logic [csp_pkg::REGISTER_W-1:0]   pass_write_address;
    logic [csp_pkg::WORD_W-1:0]       pass_write_word;

    csp_core u_core (
        .clk                 (clk),
        .reset_n             (reset_n),
        .pass_start          (pass_start),
        .held                (held),
        .cycle               (cycle),
        .fetch_address       (fetch_address),
        .fetch_row           (fetch_row),
        .rom_op              (rom_op),
        .control_word        (control_word),
        .read_r_even_index   (read_r_even_index),
        .read_r_odd_index    (read_r_odd_index),
        .read_r_pair         (read_r_pair),
        .read_x_even_index   (read_x_even_index),
        .read_x_odd_index    (read_x_odd_index),
        .read_x_pair         (read_x_pair),
        .read_y_even_index   (read_y_even_index),
        .read_y_odd_index    (read_y_odd_index),
        .read_y_pair         (read_y_pair),
        .probe_request       (probe_request),
        .probe_index         (probe_address[csp_pkg::REGISTER_W-1:1]),
        .write_even_enable   (write_even_enable),
        .write_odd_enable    (write_odd_enable),
        .write_index         (write_index),
        .write_even_data     (write_even_data),
        .write_odd_data      (write_odd_data),
        .extra_write_enable  (pass_write_enable),
        .extra_write_address (pass_write_address),
        .extra_write_word    (pass_write_word),
        .sink_write_enable   (sink_write_enable),
        .sink_write_address  (sink_write_address),
        .sink_write_data     (sink_write_data)
    );

    csp_pass u_pass (
        .clk                (clk),
        .reset_n            (reset_n),
        .pass_start         (pass_start),
        .cycle              (cycle),
        .pass_counter       (pass_counter),
        .fifo_pop           (fifo_pop),
        .fifo_committed     (fifo_committed),
        .fifo_head_valid    (fifo_head_valid),
        .fifo_head_dword    (fifo_head_dword),
        .dmem_write_enable  (pass_write_enable),
        .dmem_write_address (pass_write_address),
        .dmem_write_word    (pass_write_word),
        .probe_request      (probe_request),
        .dmem_read_pair     (read_r_pair),
        .probe_pair         (probe_pair)
    );

    // DMEM's three copies: every one takes every write; the R copy is the probe's while the core is idle
    csp_dmem u_dmem_r (
        .clk (clk),
        .write_even_enable (write_even_enable), .write_odd_enable (write_odd_enable), .write_index (write_index),
        .write_even_data (write_even_data), .write_odd_data (write_odd_data),
        .read_even_index (read_r_even_index), .read_odd_index (read_r_odd_index), .read_pair (read_r_pair)
    );
    csp_dmem u_dmem_x (
        .clk (clk),
        .write_even_enable (write_even_enable), .write_odd_enable (write_odd_enable), .write_index (write_index),
        .write_even_data (write_even_data), .write_odd_data (write_odd_data),
        .read_even_index (read_x_even_index), .read_odd_index (read_x_odd_index), .read_pair (read_x_pair)
    );
    csp_dmem u_dmem_y (
        .clk (clk),
        .write_even_enable (write_even_enable), .write_odd_enable (write_odd_enable), .write_index (write_index),
        .write_even_data (write_even_data), .write_odd_data (write_odd_data),
        .read_even_index (read_y_even_index), .read_odd_index (read_y_odd_index), .read_pair (read_y_pair)
    );

endmodule
`default_nettype wire
