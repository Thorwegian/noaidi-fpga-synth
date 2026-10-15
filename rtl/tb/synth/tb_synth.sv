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

`ifdef GATE
    GSR GSR (.GSRI(1'b1));
    // the synthesized netlist has no hierarchy to look into: the SPI side only
    assign sample_tick = 1'b0;
    assign out_left    = '0;
    assign out_right   = '0;
    assign mix_left    = '0;
    assign mix_right   = '0;
    assign passes      = '0;
    export "DPI-C" function synth_register;
    export "DPI-C" function synth_sink;
    export "DPI-C" function synth_pointer;
    function int synth_register(input int address); return 0; endfunction
    function int synth_sink(input int offset); return 0; endfunction
    function int synth_pointer(input int partial, input int position); return 0; endfunction
`else
    assign sample_tick = dut.sample_tick;
    assign out_left    = dut.out_left;
    assign out_right   = dut.out_right;
    assign mix_left    = dut.sample_left;
    assign mix_right   = dut.sample_right;
    assign passes      = dut.u_csp.pass_count;

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

`endif
endmodule
`default_nettype wire
