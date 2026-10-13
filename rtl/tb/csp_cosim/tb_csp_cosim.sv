//------------------------------------------------------------------------
// tb_csp_cosim.sv -- the new CSP, wrapped for the C++ co-simulation
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The pieces of the new CSP (rtl/csp) as the real design will connect
// them, plus a stand-in for the sink area's two pages, driven by
// csp_cosim.cpp. The harness runs the same programs and firmware writes
// on tools/csp's reference model and compares the two after every pass.
// It reads the RTL's state through the DPI functions below, which look
// into the hierarchy, so the RTL itself carries no debug ports.
//------------------------------------------------------------------------
`default_nettype none
module tb_csp_cosim (
    input  wire                                 clk,
    input  wire                                 reset_n,
    input  wire                                 pass_start,
    input  wire                                 held,

    // SPI side, driven by the harness on its own clock
    input  wire                                 sclk,
    input  wire                                 imem_write_enable,
    input  wire [csp_pkg::PROGRAM_W-1:0]        imem_write_address,
    input  wire [35:0]                          imem_write_data,
    input  wire                                 queue_write_enable,
    input  wire [csp_pkg::REGISTER_W-1:0]       queue_write_address,
    input  wire [csp_pkg::WORD_W-1:0]           queue_write_data,
    input  wire                                 swap,

    output logic                                pass_done
);

    logic [csp_pkg::PROGRAM_W-1:0] fetch_address;
    logic [35:0]                   fetch_data;
    logic                          queue_pop, queue_committed, queue_full;
    logic [csp_pkg::REGISTER_W-1:0] queue_address;
    logic [csp_pkg::WORD_W-1:0]    queue_data;
    logic                          sink_write_enable;
    logic [9:0]                    sink_write_address;
    logic [csp_pkg::WORD_W-1:0]    sink_write_data;

    csp_instruction_memory u_instruction_memory (
        .sclk          (sclk),
        .held          (held),
        .write_enable  (imem_write_enable),
        .write_address (imem_write_address),
        .write_data    (imem_write_data),
        .clk           (clk),
        .fetch_address (fetch_address),
        .fetch_data    (fetch_data)
    );

    csp_write_queue u_write_queue (
        .sclk          (sclk),
        .sclk_reset_n  (reset_n),
        .write_enable  (queue_write_enable),
        .write_address (queue_write_address),
        .write_data    (queue_write_data),
        .swap          (swap),
        .full          (queue_full),
        .clk           (clk),
        .reset_n       (reset_n),
        .pop           (queue_pop),
        .committed     (queue_committed),
        .head_address  (queue_address),
        .head_data     (queue_data)
    );

    csp_core u_core (
        .clk                (clk),
        .reset_n            (reset_n),
        .pass_start         (pass_start),
        .held               (held),
        .fetch_address      (fetch_address),
        .fetch_data         (fetch_data),
        .queue_pop          (queue_pop),
        .queue_committed    (queue_committed),
        .queue_address      (queue_address),
        .queue_data         (queue_data),
        .sink_write_enable  (sink_write_enable),
        .sink_write_address (sink_write_address),
        .sink_write_data    (sink_write_data),
        .pass_done          (pass_done)
    );

    // The sink area's two pages: the CSP writes the shadow page, the
    // partials (here, the harness) read the other; they flip at the end
    // of a pass.
    logic [csp_pkg::WORD_W-1:0] sink_page [2][csp_pkg::SINK_COUNT];
    logic                       active_page;
    initial begin
        active_page = 1'b0;
        for (int offset = 0; offset < csp_pkg::SINK_COUNT; offset++) begin
            sink_page[0][offset] = '0;
            sink_page[1][offset] = '0;
        end
    end
    always_ff @(posedge clk) begin
        if (sink_write_enable) begin
            sink_page[!active_page][sink_write_address] <= sink_write_data;
        end
        if (pass_done) begin
            active_page <= !active_page;
        end
    end

    // ---- the harness's view of the state ---------------------------------------
    export "DPI-C" function cosim_register;
    export "DPI-C" function cosim_sink;
    export "DPI-C" function cosim_index;
    export "DPI-C" function cosim_accumulator;
    export "DPI-C" function cosim_flags;

    function int cosim_register(input int address);
        logic [csp_pkg::WORD_W-1:0] word;
        int index;
        index = address >>> 1;
        word = address[0] ? u_core.u_register_file.g_copy[0].odd_bank[index]
                          : u_core.u_register_file.g_copy[0].even_bank[index];
        return int'($signed(word));
    endfunction

    function int cosim_sink(input int offset);
        return int'($signed(sink_page[active_page][offset]));
    endfunction

    function int cosim_index(input int which);
        return which != 0 ? int'(u_core.index_j) : int'(u_core.index_i);
    endfunction

    function longint cosim_accumulator();
        return longint'(u_core.accumulator);
    endfunction

    function int cosim_flags();
        return {29'd0, u_core.flag_overflow, u_core.flag_zero, u_core.flag_negative};
    endfunction

endmodule
`default_nettype wire
