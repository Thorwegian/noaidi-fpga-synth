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
module tb_csp_cosim #(
    parameter int REF_VOICES = 0     // adsr.sv references, for the program benches
) (
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
    input  wire [csp_pkg::QUEUE_ADDRESS_W-1:0]  queue_write_address,
    input  wire [csp_pkg::WORD_W-1:0]           queue_write_data,
    input  wire                                 swap,

    output logic                                pass_done
);

    logic [csp_pkg::PROGRAM_W-1:0] fetch_address;
    logic [35:0]                   fetch_data;
    logic                          queue_pop, queue_committed, queue_full;
    logic [csp_pkg::QUEUE_ADDRESS_W-1:0] queue_address;
    logic [csp_pkg::WORD_W-1:0]    queue_data;
    logic                          sink_write_enable, sink_write_both;
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
        .sink_write_both    (sink_write_both),
        .sink_write_address (sink_write_address),
        .sink_write_data    (sink_write_data),
        .pass_done          (pass_done)
    );

    // The sink area. The harness reads the active page through the
    // hierarchy (cosim_sink); the partial pipeline's ports are idle here.
    csp_sink_area #(.READ_PORTS(1)) u_sink_area (
        .clk           (clk),
        .reset_n       (reset_n),
        .write_enable  (sink_write_enable),
        .write_both    (sink_write_both),
        .write_address (sink_write_address),
        .write_data    (sink_write_data),
        .pass_done     (pass_done),
        .read_address  ('0),
        .read_data     ()
    );

    // The cycle after the last instruction of the program issued this pass
    // (the NOPs in memory past it run on): what the reference model reports
    // as the pass's cycles.
    int program_length = 0;
    int issue_end;
    always_ff @(posedge clk) begin
        if (pass_start) begin
            issue_end <= 0;
        end else if (u_core.issue && int'(u_core.decode_pc) < program_length) begin
            issue_end <= int'(u_core.pass_cycle) + 1;
        end
    end

    // +rtltrace: every issue, in the format of the model's trace
    // (CSP_TRACE_PROGRAM), to diff the two.
    bit trace_issues;
    initial trace_issues = $test$plusargs("rtltrace");
    always_ff @(posedge clk) begin
        if (trace_issues && u_core.writes_result_now) begin
            if (u_core.rf_write_wide) begin
                $display("rtl write %0d %0d", int'(u_core.rf_write_address),
                         $signed(u_core.rf_write_data[35:18]));
                $display("rtl write %0d %0d", int'(u_core.rf_write_address) + 1,
                         $signed(u_core.rf_write_data[17:0]));
            end else begin
                $display("rtl write %0d %0d", int'(u_core.rf_write_address),
                         $signed(u_core.rf_write_data[17:0]));
            end
        end
        if (trace_issues && u_core.sink_write_enable) begin
            $display("rtl sink %0d %0d", int'(u_core.sink_write_address),
                     $signed(u_core.sink_write_data));
        end
        if (trace_issues && u_core.issue && int'(u_core.decode_pc) < program_length) begin
            $display("rtl pc %0d cycle %0d i %0d j %0d", int'(u_core.decode_pc),
                     int'(u_core.pass_cycle), int'(u_core.decode_index_i),
                     int'(u_core.decode_index_j));
        end
    end

    // ---- adsr.sv references: the envelopes the CSP program replaces -------------------
    // REF_VOICES instances of the old unit, stepped at 96 kHz (twice a pass,
    // at cycles 10 and 778) with the gate and the coefficients the harness
    // sets, so the harness can compare their levels with the program's.
    localparam int REFS = REF_VOICES > 0 ? REF_VOICES : 1;
    logic [REFS-1:0]       ref_gate;
    logic [31:0]           ref_rate_ad  [REFS];
    logic [31:0]           ref_rate_dsr [REFS];
    logic [27:0]           ref_state    [REFS];
    logic                  ref_step;
    initial begin
        ref_gate = '0;
        for (int voice = 0; voice < REFS; voice++) begin
            ref_rate_ad[voice]  = '0;
            ref_rate_dsr[voice] = '0;
        end
    end

    logic [10:0] ref_cycle;
    always_ff @(posedge clk) begin
        if (pass_start) ref_cycle <= '0;
        else ref_cycle <= ref_cycle + 1'b1;
        ref_step <= REF_VOICES > 0 && (ref_cycle == 11'd9 || ref_cycle == 11'd777);
    end

    generate
        for (genvar voice = 0; voice < REFS; voice++) begin : g_ref
            if (REF_VOICES > 0) begin : g_on
                logic [27:0] state_out;
                logic        state_we;
                logic signed [17:0] level_out;
                adsr u_adsr (
                    .clk        (clk),
                    .rst_n      (reset_n),
                    .step_en    (ref_step),
                    .state_in   (ref_state[voice]),
                    .gate       (ref_gate[voice]),
                    .rate_ad    (ref_rate_ad[voice]),
                    .rate_dsr   (ref_rate_dsr[voice]),
                    .level_out  (level_out),
                    .state_out  (state_out),
                    .state_we   (state_we)
                );
                always_ff @(posedge clk or negedge reset_n) begin
                    if (!reset_n) ref_state[voice] <= '0;
                    else if (state_we) ref_state[voice] <= state_out;
                end
            end else begin : g_off
                initial ref_state[voice] = '0;
            end
        end
    endgenerate

    export "DPI-C" function cosim_ref_set;
    export "DPI-C" function cosim_ref_state;

    function void cosim_ref_set(input int voice, input int gate, input int rate_ad,
                                input int rate_dsr);
        ref_gate[voice]     = gate != 0;
        ref_rate_ad[voice]  = rate_ad;
        ref_rate_dsr[voice] = rate_dsr;
    endfunction

    function int cosim_ref_state(input int voice);
        return int'(ref_state[voice]);
    endfunction

    // ---- osc_core references: the LFO waveforms the CSP programs replace --------------
    // osc_core is a combinational function of the phase: the harness sets one,
    // evaluates, and reads the four shapes.
    logic signed [23:0] osc_phase;
    logic signed [17:0] osc_wave [4];
    initial osc_phase = '0;
    generate
        for (genvar shape = 0; shape < 4; shape++) begin : g_osc
            if (REF_VOICES > 0) begin : g_on
                osc_core u_osc (
                    .phase_next (osc_phase),
                    .duty       (24'sd0),
                    .wave       (2'(shape)),
                    .sample_out (osc_wave[shape])
                );
            end else begin : g_off
                initial osc_wave[shape] = '0;
            end
        end
    endgenerate

    export "DPI-C" function cosim_osc_set;
    export "DPI-C" function cosim_osc_wave;

    function void cosim_osc_set(input int phase);
        osc_phase = 24'(phase);
    endfunction

    function int cosim_osc_wave(input int shape);
        return int'(osc_wave[shape]);
    endfunction

    // ---- the harness's view of the state ---------------------------------------
    export "DPI-C" function cosim_register;
    export "DPI-C" function cosim_sink;
    export "DPI-C" function cosim_index;
    export "DPI-C" function cosim_accumulator;
    export "DPI-C" function cosim_flags;
    export "DPI-C" function cosim_cycles;
    export "DPI-C" function cosim_set_program_length;

    function int cosim_register(input int address);
        logic [csp_pkg::WORD_W-1:0] word;
        int index;
        index = address >>> 1;
        word = address[0] ? u_core.u_register_file.g_copy[0].odd_bank[index]
                          : u_core.u_register_file.g_copy[0].even_bank[index];
        return int'($signed(word));
    endfunction

    function int cosim_sink(input int offset);
        return u_sink_area.active_page
            ? int'($signed(u_sink_area.g_port[0].g_page[1].words[offset]))
            : int'($signed(u_sink_area.g_port[0].g_page[0].words[offset]));
    endfunction

    function int cosim_index(input int which);
        return which != 0 ? int'(u_core.index_j) : int'(u_core.index_i);
    endfunction

    function longint cosim_accumulator();
        return longint'(u_core.accumulator);
    endfunction

    function void cosim_set_program_length(input int length);
        program_length = length;
    endfunction

    function int cosim_cycles();
        return issue_end;
    endfunction

    function int cosim_flags();
        return {29'd0, u_core.flag_overflow, u_core.flag_zero, u_core.flag_negative};
    endfunction

endmodule
`default_nettype wire
