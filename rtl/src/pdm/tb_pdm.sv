`timescale 1ns/1ps

module tb_pdm;

parameter NBITS = 8;
parameter OSR = 512;

reg clk = 1'b0;
reg rst = 1'b1;
reg [NBITS-1:0] din = 0;
wire dout;
wire [NBITS-1:0] error;

pdm #(
    .NBITS(NBITS)
) uut_tx (
    .clk(clk),
    .rst(rst),
    .din(din),
    .dout(dout),
    .error(error)
);

always #100 clk = ~clk;

integer signed i;
initial begin
    #200;
    rst <= 1'b0;
    forever begin
        for(i = 0; i < 255; i = i + 1) begin
            din <= i;
            #1600;
        end
        for(i = 255; i >= 0; i = i - 1) begin
            din <= i;
            #1600;
        end
    end
end

reg [OSR-1:0] dout_history = 0;
real wave_out;
integer idx;
real dout_sum;

always @(negedge clk) begin
    // Shift register to store the bitstream history
    dout_history <= {dout_history[OSR-2:0], dout};
end

real OSR_2 = OSR / 2;
real OSR_4 = OSR / 4;
always @(posedge clk) begin
    dout_sum = 0;
    for (idx = 1; idx < OSR; idx = idx + 1) begin
        if(idx < OSR / 2) begin
            dout_sum = dout_sum + (dout_history[idx] ? idx : -idx) / OSR_4;
        end else begin
            dout_sum = dout_sum + (dout_history[idx] ? OSR - idx : -OSR + idx) / OSR_4;
        end
    end

    // Normalize the output to the range [-1.0, 1.0]
    wave_out = 1 + dout_sum / OSR_2;
end

endmodule