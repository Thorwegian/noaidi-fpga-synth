// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_csp_cosim.sv — the CSP, wrapped for the C++ co-simulation
//
// IMEM, the decode ROM, the write FIFO and csp (the core, DMEM's three
// copies and the pass) as top.sv connects them, plus a stand-in for the
// sink area's two pages, all driven by csp_cosim.cpp, which runs the same
// programs and firmware writes on tools/csp's reference model and compares
// the two after every pass. The harness reads the RTL's state through the
// DPI functions below, which look into the hierarchy, so the RTL itself
// carries no debug ports.
//------------------------------------------------------------------------
`default_nettype none
module tb_csp_cosim (
    input  wire                              clk,
    input  wire                              reset_n,
    input  wire                              pass_start,
    input  wire                              held,

    // the SPI side, driven by the harness on its own clock
    input  wire                              sclk,
    input  wire                              imem_load,
    input  wire                              imem_upper,
    input  wire [csp_pkg::PROGRAM_W-1:0]     imem_row,
    input  wire [csp_pkg::DWORD_W-1:0]       imem_dword,
    input  wire                              rom_load,
    input  wire [csp_pkg::ROM_ADDRESS_W-1:0] rom_row,
    input  wire [csp_pkg::ROM_W-1:0]         rom_word,
    input  wire                              fifo_write,
    input  wire [csp_pkg::DWORD_W-1:0]       fifo_dword,
    input  wire                              swap
);

    logic [csp_pkg::PROGRAM_W-1:0]      fetch_address;
    logic [csp_pkg::ROW_W-1:0]          fetch_row;
    logic [csp_pkg::ROM_ADDRESS_W-1:0]  rom_op;
    logic [csp_pkg::ROM_W-1:0]          control_word;
    logic [csp_pkg::DWORD_W-1:0]        imem_read_dword;
    logic [csp_pkg::ROM_W-1:0]          rom_read_word;

    csp_imem u_imem (
        .sclk (sclk), .load_enable (imem_load), .load_row (imem_row), .load_upper (imem_upper), .load_dword (imem_dword),
        .read_row (imem_row), .read_upper (imem_upper), .read_dword (imem_read_dword),
        .clk (clk), .held (held), .fetch_address (fetch_address), .fetch_row (fetch_row)
    );

    csp_decode_rom u_rom (
        .sclk (sclk), .load_enable (rom_load), .load_row (rom_row), .load_word (rom_word),
        .read_row (rom_row), .read_word (rom_read_word),
        .clk (clk), .held (held), .op (rom_op), .control_word (control_word)
    );

    logic                       fifo_full, fifo_pop, fifo_committed, fifo_head_valid;
    logic [15:0]                fifo_dropped;
    logic [csp_pkg::DWORD_W-1:0] fifo_head_dword;
    logic [csp_pkg::FIFO_POINTER_W-1:0] fifo_read_gray;

    csp_write_fifo u_fifo (
        .sclk (sclk), .sclk_reset_n (reset_n), .write_enable (fifo_write), .write_dword (fifo_dword),
        .swap (swap), .full (fifo_full), .dropped (fifo_dropped),
        .clk (clk), .reset_n (reset_n), .pop (fifo_pop), .committed (fifo_committed), .head_valid (fifo_head_valid),
        .head_dword (fifo_head_dword), .read_pointer_gray (fifo_read_gray)
    );

    logic [csp_pkg::CYCLE_W-1:0]  cycle;
    logic [31:0]                  pass_counter;
    logic [csp_pkg::WIDE_W-1:0]   probe_pair;
    logic                         sink_write_enable;
    logic [csp_pkg::SINK_WORD_W-1:0] sink_write_address;
    logic [csp_pkg::WORD_W-1:0]   sink_write_data;

    csp u_csp (
        .clk (clk), .reset_n (reset_n), .pass_start (pass_start), .held (held),
        .fetch_address (fetch_address), .fetch_row (fetch_row), .rom_op (rom_op), .control_word (control_word),
        .fifo_pop (fifo_pop), .fifo_committed (fifo_committed), .fifo_head_valid (fifo_head_valid),
        .fifo_head_dword (fifo_head_dword),
        .probe_address (csp_pkg::REGISTER_W'(csp_pkg::PARK_REGISTER)), .probe_pair (probe_pair),
        .cycle (cycle), .pass_counter (pass_counter),
        .sink_write_enable (sink_write_enable), .sink_write_address (sink_write_address), .sink_write_data (sink_write_data)
    );

    // ---- the sink area: two pages, the program writes the shadow one, the pages flip at a pass's start ----
    logic [csp_pkg::WORD_W-1:0] sink_pages [2][csp_pkg::SINK_COUNT];
    logic                       shadow_page = 1'b0;      // the first pass's start flips it to the model's page 1
    initial for (int page = 0; page < 2; page++) for (int word = 0; word < csp_pkg::SINK_COUNT; word++) sink_pages[page][word] = '0;
    always_ff @(posedge clk) begin
        if (pass_start) shadow_page <= ~shadow_page;
        if (sink_write_enable) sink_pages[shadow_page][sink_write_address] <= sink_write_data;
    end

    // ---- the cycles a pass took: the issue cycle after the program's last row (the model's report.cycles) ----
    int program_length = 0;
    int last_issue_end = 0;
    always_ff @(posedge clk) begin
        if (pass_start) last_issue_end <= 0;
        else if (u_csp.u_core.a_present && int'(u_csp.u_core.a_pc) < program_length)
            last_issue_end <= int'(cycle) - csp_pkg::FIRST_ISSUE_CYCLE + 1;
    end

    // ---- the harness reads state here ----
    export "DPI-C" function cosim_register;
    export "DPI-C" function cosim_sink;
    export "DPI-C" function cosim_index;
    export "DPI-C" function cosim_accumulator;
    export "DPI-C" function cosim_flags;
    export "DPI-C" function cosim_cycles;
    export "DPI-C" function cosim_set_program_length;
    export "DPI-C" function cosim_row_rule_violations;
    export "DPI-C" function cosim_fifo_dropped;

    function int cosim_register(input int address);
        logic [csp_pkg::WORD_W-1:0] word;
        word = address[0] ? u_csp.u_dmem_r.odd_bank[address >> 1] : u_csp.u_dmem_r.even_bank[address >> 1];
        return int'($signed(word));
    endfunction

    function int cosim_sink(input int offset);
        return int'($signed(sink_pages[shadow_page][offset]));
    endfunction

    function int cosim_index(input int which);
        return which == 0 ? int'(u_csp.u_core.index_i) : int'(u_csp.u_core.index_j);
    endfunction

    function longint cosim_accumulator();
        return longint'(u_csp.u_core.accumulator);
    endfunction

    function int cosim_flags();
        return {29'd0, u_csp.u_core.flag_overflow, u_csp.u_core.flag_zero, u_csp.u_core.flag_negative};
    endfunction

    function int cosim_cycles();
        return last_issue_end;
    endfunction

    function void cosim_set_program_length(input int length);
        program_length = length;
    endfunction

    function int cosim_row_rule_violations();
        return u_csp.u_dmem_r.row_rule_violations + u_csp.u_dmem_x.row_rule_violations + u_csp.u_dmem_y.row_rule_violations;
    endfunction

    function int cosim_fifo_dropped();
        return int'(fifo_dropped);
    endfunction

    // +rtltrace: every row entering A, to compare with the model's CSP_TRACE
    bit trace_rows;
    initial trace_rows = $test$plusargs("rtltrace");
    always_ff @(posedge clk) begin
        if (trace_rows && u_csp.u_core.a_present && int'(u_csp.u_core.a_pc) < program_length)
            $display("rtl pc %0d cycle %0d i %0d j %0d live %0d", int'(u_csp.u_core.a_pc),
                     int'(cycle) - csp_pkg::FIRST_ISSUE_CYCLE, int'(u_csp.u_core.index_i), int'(u_csp.u_core.index_j),
                     u_csp.u_core.a_live);
        if (trace_rows && u_csp.u_core.write_even_enable)
            $display("rtl write even row %0d %0d", int'(u_csp.u_core.write_index), $signed(u_csp.u_core.write_even_data));
        if (trace_rows && u_csp.u_core.write_odd_enable)
            $display("rtl write odd row %0d %0d", int'(u_csp.u_core.write_index), $signed(u_csp.u_core.write_odd_data));
    end

endmodule
`default_nettype wire
