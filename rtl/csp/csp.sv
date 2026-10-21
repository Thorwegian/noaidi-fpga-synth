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
// 1473, its W seven later) and the window's begin at 1484, so an OR of the
// two, with the core's address winning, is the whole arbitration; likewise
// the probe's read at the pass's last cycle uses the R copy while the core is
// idle.
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

    // the core's ports
    logic                            core_read_r_enable, core_read_r_wide, core_read_x_enable, core_read_y_enable, core_read_y_wide;
    logic [csp_pkg::REGISTER_W-1:0]  core_read_r_address, core_read_x_address, core_read_y_address;
    logic [csp_pkg::WIDE_W-1:0]      read_r_pair, read_x_pair, read_y_pair;
    logic                            core_write_enable, core_write_wide;
    logic [csp_pkg::REGISTER_W-1:0]  core_write_address;
    logic [csp_pkg::WIDE_W-1:0]      core_write_data;

    csp_core u_core (
        .clk                (clk),
        .reset_n            (reset_n),
        .pass_start         (pass_start),
        .held               (held),
        .cycle              (cycle),
        .fetch_address      (fetch_address),
        .fetch_row          (fetch_row),
        .rom_op             (rom_op),
        .control_word       (control_word),
        .read_r_enable      (core_read_r_enable),
        .read_r_wide        (core_read_r_wide),
        .read_r_address     (core_read_r_address),
        .read_r_pair        (read_r_pair),
        .read_x_enable      (core_read_x_enable),
        .read_x_address     (core_read_x_address),
        .read_x_pair        (read_x_pair),
        .read_y_enable      (core_read_y_enable),
        .read_y_wide        (core_read_y_wide),
        .read_y_address     (core_read_y_address),
        .read_y_pair        (read_y_pair),
        .write_enable       (core_write_enable),
        .write_wide         (core_write_wide),
        .write_address      (core_write_address),
        .write_data         (core_write_data),
        .sink_write_enable  (sink_write_enable),
        .sink_write_address (sink_write_address),
        .sink_write_data    (sink_write_data)
    );

    // the pass: the window's writes and the counter's, and the probe's read
    logic                            pass_write_enable, probe_read_enable;
    logic [csp_pkg::REGISTER_W-1:0]  pass_write_address, probe_read_address;
    logic [csp_pkg::WORD_W-1:0]      pass_write_word;

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
        .probe_address      (probe_address),
        .dmem_read_enable   (probe_read_enable),
        .dmem_read_address  (probe_read_address),
        .dmem_read_pair     (read_r_pair),
        .probe_pair         (probe_pair)
    );

    // the one write port, to every copy
    wire                            write_enable  = core_write_enable | pass_write_enable;
    wire                            write_wide    = core_write_enable & core_write_wide;
    wire [csp_pkg::REGISTER_W-1:0]  write_address = core_write_enable ? core_write_address : pass_write_address;
    wire [csp_pkg::WIDE_W-1:0]      write_data    = core_write_enable ? core_write_data : {{csp_pkg::WORD_W{1'b0}}, pass_write_word};

    // the R copy is the probe's while the core is idle
    csp_dmem u_dmem_r (
        .clk           (clk),
        .write_enable  (write_enable),
        .write_address (write_address),
        .write_wide    (write_wide),
        .write_data    (write_data),
        .read_enable   (core_read_r_enable | probe_read_enable),
        .read_address  (probe_read_enable ? probe_read_address : core_read_r_address),
        .read_wide     (core_read_r_wide | probe_read_enable),
        .read_pair     (read_r_pair)
    );
    csp_dmem u_dmem_x (
        .clk           (clk),
        .write_enable  (write_enable),
        .write_address (write_address),
        .write_wide    (write_wide),
        .write_data    (write_data),
        .read_enable   (core_read_x_enable),
        .read_address  (core_read_x_address),
        .read_wide     (1'b0),
        .read_pair     (read_x_pair)
    );
    csp_dmem u_dmem_y (
        .clk           (clk),
        .write_enable  (write_enable),
        .write_address (write_address),
        .write_wide    (write_wide),
        .write_data    (write_data),
        .read_enable   (core_read_y_enable),
        .read_address  (core_read_y_address),
        .read_wide     (core_read_y_wide),
        .read_pair     (read_y_pair)
    );

endmodule
`default_nettype wire
