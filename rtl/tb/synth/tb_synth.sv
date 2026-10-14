//------------------------------------------------------------------------
// tb_synth.sv -- the whole synthesizer, wrapped for the system bench
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// `top` as the board has it, with the audio the listener hears (the output
// low-pass's, after the test-tone mux) and the pipeline's own mix brought
// out beside it, a flag for each sample, and the CSP's pass counter. The
// bench (synth_sim.cpp) drives the SPI pins and the clock.
//------------------------------------------------------------------------
`default_nettype none
module tb_synth (
    input  wire        sysclk,
    input  wire        rst,

    input  wire        sclk,
    input  wire        cs,
    input  wire        mosi,
    output wire        miso,

    output wire        sample_tick,          // a new sample (96 kHz)
    output wire signed [23:0] out_left,      // what the listener hears
    output wire signed [23:0] out_right,
    output wire signed [23:0] mix_left,      // the pipeline's mix, before the low-pass
    output wire signed [23:0] mix_right,
    output wire [17:0] passes                // the CSP's pass counter
);

    wire [5:0] led;
    wire i2s_bclk, i2s_lrclk, i2s_data, spdif_out, spdif48_out;

    top dut (
        .sysclk      (sysclk),
        .rst         (rst),
        .led         (led),
        .sclk        (sclk),
        .cs          (cs),
        .mosi        (mosi),
        .miso        (miso),
        .i2s_bclk    (i2s_bclk),
        .i2s_lrclk   (i2s_lrclk),
        .i2s_data    (i2s_data),
        .spdif_out   (spdif_out),
        .spdif48_out (spdif48_out)
    );

    assign sample_tick = dut.sample_tick;
    assign out_left    = dut.out_left;
    assign out_right   = dut.out_right;
    assign mix_left    = dut.sample_left;
    assign mix_right   = dut.sample_right;
    assign passes      = dut.u_csp.pass_count;

    int last_csp_sink_data = 0;
    int csp_sink_writes = 0, firmware_sink_writes = 0, last_csp_sink_address = -1, flips = 0;
    always_ff @(posedge sysclk) begin
        if (dut.sink_write_enable && !dut.sink_write_both) begin
            csp_sink_writes <= csp_sink_writes + 1;
            last_csp_sink_address <= int'(dut.sink_write_address);
            last_csp_sink_data <= int'($signed(dut.sink_write_data));
        end
        if (dut.sink_write_enable && dut.sink_write_both) firmware_sink_writes <= firmware_sink_writes + 1;
        if (dut.pass_done) flips <= flips + 1;
    end
    int queued = 0, dropped_full = 0, popped = 0;
    always @(posedge sclk) begin
        if (dut.queue_write_enable) begin
            queued <= queued + 1;
            if (dut.u_write_queue.full) dropped_full <= dropped_full + 1;
        end
    end
    always_ff @(posedge sysclk) if (dut.queue_pop) popped <= popped + 1;
    export "DPI-C" function synth_queue_counters;
    function int synth_queue_counters(input int which);
        return which == 0 ? queued : which == 1 ? dropped_full : popped;
    endfunction
    export "DPI-C" function synth_counters;
    function int synth_counters(input int which);
        case (which)
            0: return csp_sink_writes;
            1: return firmware_sink_writes;
            2: return last_csp_sink_address;
            4: return last_csp_sink_data;
            5: return dut.u_sink_area.active_page ? 1 : 0;
            default: return flips;
        endcase
    endfunction

    // ---- the harness's view of the CSP and the pipeline's pointers ------------
    export "DPI-C" function synth_register;
    export "DPI-C" function synth_sink;
    export "DPI-C" function synth_pointer;

    function int synth_register(input int address);
        logic [csp_pkg::WORD_W-1:0] word;
        word = address[0] ? dut.u_csp.u_register_file.g_copy[0].odd_bank[address >>> 1]
                          : dut.u_csp.u_register_file.g_copy[0].even_bank[address >>> 1];
        return int'($signed(word));
    endfunction

    // the page the partials read
    function int synth_sink(input int offset);
        return int'($signed(dut.u_sink_area.page_words[dut.u_sink_area.active_page][offset]));
    endfunction

    // pointer `position` of a partial
    function int synth_pointer(input int partial, input int position);
        logic [107:0] entry;
        entry = {dut.u_partial_pipeline.pointer_block_2[partial],
                 dut.u_partial_pipeline.pointer_block_1[partial],
                 dut.u_partial_pipeline.pointer_block_0[partial]};
        return int'(entry[position * 10 +: 10]);
    endfunction

endmodule
`default_nettype wire
