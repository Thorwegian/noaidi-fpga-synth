module pdm #(parameter NBITS = 10)
(
  input wire                      clk,
  input wire [NBITS-1:0]          din,
  input wire                      rst,
  output reg                      dout,
  output reg [NBITS-1:0]          error = 0
);

  localparam integer MAX = 2**NBITS - 1;
  reg [NBITS-1:0] din_reg;
  reg [NBITS-1:0] error_0 = 0;
  reg [NBITS-1:0] error_1 = 0;

  always @(posedge clk) begin
    din_reg <= din;
    error_1 <= error + MAX - din_reg;
    error_0 <= error - din_reg;
  end

  always @(posedge clk) begin
    if (rst == 1'b1) begin
      dout <= 0;
      error <= 0;
    end
    else if (din_reg >= error) begin
      dout <= 1;
      error <= error_1;
    end else begin
      dout <= 0;
      error <= error_0;
    end
  end

endmodule