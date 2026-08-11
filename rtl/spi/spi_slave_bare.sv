`default_nettype none
module spi_slave_bare (
    input  wire       i_sclk,
    input  wire       i_cs_n,
    input  wire       i_mosi,
    output wire       o_miso
);
    reg [7:0] shreg_rx;
    reg [7:0] shreg_tx;
    reg       miso_q;

	reg held = 0;
	always @(posedge i_sclk)
		held <= 1'b1;          // unconditional set
	assign o_miso = held;
endmodule
