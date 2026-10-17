// bsram_probe.sv — does the place-and-route tool time a path from a block RAM?
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A block RAM read feeds an eight-deep chain of 18-bit adders and parities
// into a flop. On silicon that chain is 8–10 ns; a tool that times it reports
// a critical path from the memory's output. nextpnr-himbaechel (gowin,
// 2026-07-30) reports 600 MHz and the address counter, the chain absent: it
// does not time paths that start at a BSRAM output (docs/csp_isa.md, 12).
`default_nettype none
module bsram_probe (
    input  wire  clk,
    output logic result
);
    logic [9:0]  address = '0;
    logic [17:0] memory [1024];
    logic [17:0] word;
    always_ff @(posedge clk) begin
        address         <= address + 1'b1;
        memory[address] <= {address, address[7:0]};
        word            <= memory[~address];
    end
    logic [17:0] chain [8];
    always_comb begin
        chain[0] = word;
        for (int k = 1; k < 8; k++) chain[k] = {chain[k-1][16:0], ^chain[k-1]} + 18'd7;
    end
    always_ff @(posedge clk) result <= ^chain[7];
endmodule
`default_nettype wire
