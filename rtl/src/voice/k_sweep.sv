//--------------------------------------------------------------------
// k_sweep.sv — Coefficient LUT sweep for SVF testing
//
// Sweeps through precomputed SVF coefficients:
//   K         (24-bit Q0.24 unsigned)
//   inv_res_K (18-bit Q3.14 signed)
//   inv_div   (18-bit Q3.14 signed)
//
// LUT: 320 entries, 18–18432 Hz, 32/octave, Q=1.0.
// Sweep rate: one entry every 1024 samples.
//--------------------------------------------------------------------

module k_sweep (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    strobe,

    output logic [23:0]             K_out,
    output logic signed [17:0]      inv_res_K,
    output logic signed [17:0]      inv_div
);

    // LUT ROM: 320 entries, each 16 hex chars = 64 bits.
    // Packing: [63:40]=K, [39:20]=inv_res_K, [19:0]=inv_div
    // (each 20-bit field has 2 padding bits; value is right-aligned)
    logic [63:0] lut [0:319];
    initial $readmemh("src/voice/k_lut.hex", lut);

    localparam RATE = 1024;
    logic [9:0]  counter;
    logic [8:0]  addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter   <= 0;
            addr      <= 0;
            K_out     <= 0;
            inv_res_K <= 0;
            inv_div   <= 0;
        end else if (strobe) begin
            if (counter == RATE - 1) begin
                counter   <= 0;
                K_out     <= lut[addr][63:40];
                inv_res_K <= $signed(lut[addr][37:20]);
                inv_div   <= $signed(lut[addr][17:0]);
                if (addr < 319)
                    addr <= addr + 1;
                else
                    addr <= 0;
            end else begin
                counter <= counter + 1;
            end
        end
    end

endmodule
