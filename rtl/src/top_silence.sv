//--------------------------------------------------------------------
// top_silence.sv — Tang Nano 20K doing literally nothing
//
// All outputs tied to safe idle states.  No clocks, no logic,
// no nothing.  Synthesises in seconds.
//--------------------------------------------------------------------

module top_silence (
    input  logic        clk,
    input  logic        rst,
    input  logic        uart_rx,
    input  logic        midi_rx,
    output logic [5:0]  led,
    output logic        uart_tx,
    output logic        i2s_bclk,
    output logic        i2s_lrclk,
    output logic        i2s_data,
    output logic        pa_en
);

    assign led       = 6'b111111;   // active-low, 1 = off
    assign uart_tx   = 1'b1;        // idle
    assign i2s_bclk  = 1'b0;        // no clock = DAC idle
    assign i2s_lrclk = 1'b0;
    assign i2s_data  = 1'b0;        // silence
    assign pa_en     = 1'b1;        // amp on (with zero data = silent)

endmodule
