module pdm_tx #(
    parameter BITS = 8
)(
    input wire clk,
    input wire rst_n,
    input wire signed [BITS-1:0] v_in,
    output reg bit_out
);

    // Pre-calculate integer boundaries for the feedback multiplexer
    localparam signed [BITS+1:0] MAX_VAL = (1 << (BITS - 1)) - 1;
    localparam signed [BITS+1:0] MIN_VAL = -(1 << (BITS - 1));

    // Internal registers sized to BITS+2 to handle integration headroom
    // Around BITS+6 the square oscillatioms became triangular instead
    reg signed [BITS+16:0] accum1 = 0;
    reg signed [BITS+16:0] accum2 = 0;
    wire signed [BITS+16:0] feedback;
    reg signed [BITS+16:0] avg = 0;

    // Select feedback level using the target signal length
    assign feedback = bit_out ? MAX_VAL : MIN_VAL;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accum1    <= 0;
            accum2    <= 0;
            bit_out   <= 0;
        end else begin
            // Double integration stages
            accum1 <= accum1 + (v_in - feedback);
            accum2 <= accum2 + accum1;

            // Quantizer checks sign bit of the second accumulator
            //if (accum1 + accum1 + accum2 >= 0) begin      // Second-order
            if (accum1 >= 0) begin                          // First-order
                bit_out   <= 1;
            end else begin
                bit_out   <= 0;
            end
        end
    end

endmodule