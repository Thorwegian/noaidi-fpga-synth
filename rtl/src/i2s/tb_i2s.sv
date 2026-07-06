`timescale 1ns/1ps

module tb_i2s;

parameter BITS = 16;

reg sck = 1'b0;
reg ws = 1'b0;
wire sd;
reg [BITS-1:0] data_left_in = {BITS{1'b0}};
reg [BITS-1:0] data_right_in = {BITS{1'b0}};
wire [BITS-1:0] data_left_out;
wire [BITS-1:0] data_right_out;
wire data_valid;
wire data_ready;

i2s_tx #(
    .BITS(BITS)
) uut_tx (
    .sck(sck),
    .ws(ws),
    .sd(sd),
    .data_left(data_left_in),
    .data_right(data_right_in),
    .data_ready(data_ready)
);

i2s_rx #(
    .BITS(BITS)
) uut_rx (
    .sck(sck),
    .ws(ws),
    .sd(sd),
    .data_left(data_left_out),
    .data_right(data_right_out),
    .data_valid(data_valid)
);

always #178.5 sck = ~sck;

always #(178.5 * 2 * BITS) ws = ~ws;

initial begin
    //#(178.5 * BITS);
    forever begin
        #(178.5 * 4 * BITS);
        data_left_in = 16'h8AF1;
        data_right_in = 16'h8F89;
        #(178.5 * 4 * BITS);
        data_left_in = 16'hA555;
        data_right_in = 16'hF00F;
    end
end

endmodule