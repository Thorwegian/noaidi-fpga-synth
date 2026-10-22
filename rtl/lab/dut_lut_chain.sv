//------------------------------------------------------------------------
// dut_lut_chain.sv — a device under test: LEVELS levels of LUT4 between registers
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// WIDTH chains in parallel, each LEVELS LUT4s deep: level i takes the level
// before and three fresh stimulus bits through a function no two levels
// collapse into one (an XOR, an AND and an OR, by turns). The device computes
// the chain in one cycle; the reference computes one level a cycle, which is
// one LUT between registers and safe at any clock this chip runs at, and the
// device's result is delayed to meet it. A cycle in which they differ is a
// mismatch. The report says how many LUT levels the device really has after
// synthesis; the row of the table is named by that, not by LEVELS.
//------------------------------------------------------------------------
`default_nettype none
module dut_lut_chain #(
    parameter int LEVELS = 4,
    parameter int WIDTH  = 18
) (
    input  wire                              clk,
    input  wire                              reset_n,
    input  wire [lab_pkg::STIMULUS_W-1:0]    stimulus,
    input  wire                              inject_fault,     // simulation: corrupt the device's result
    output logic                             mismatch
);

    // the level's function: the previous level and three stimulus bits
    function automatic logic level(input int index, input logic previous, input logic a, input logic b, input logic c);
        case (index % 3)
            0:       level = (previous ^ a) | (b & c);
            1:       level = (previous & a) ^ (b | c);
            default: level = (previous | a) ^ (b & ~c);
        endcase
    endfunction

    function automatic logic [WIDTH-1:0] stimulus_bits(input logic [lab_pkg::STIMULUS_W-1:0] s, input int index);
        for (int w = 0; w < WIDTH; w++) stimulus_bits[w] = s[(index * WIDTH + w) % lab_pkg::STIMULUS_W];
    endfunction

    // the stimulus registered once, the same for both
    logic [lab_pkg::STIMULUS_W-1:0] s_q;
    always_ff @(posedge clk) s_q <= stimulus;

    // ---- the device: LEVELS levels in one cycle ----
    logic [WIDTH-1:0] chain [LEVELS + 1];
    always_comb begin
        logic [WIDTH-1:0] a, b, c;
        chain[0] = stimulus_bits(s_q, 0);
        for (int l = 0; l < LEVELS; l++) begin
            a = stimulus_bits(s_q, 3 * l + 1);
            b = stimulus_bits(s_q, 3 * l + 2);
            c = stimulus_bits(s_q, 3 * l + 3);
            for (int w = 0; w < WIDTH; w++) chain[l + 1][w] = level(l, chain[l][w], a[w], b[w], c[w]);
        end
    end
    logic [WIDTH-1:0] device_q;
    always_ff @(posedge clk) device_q <= chain[LEVELS] ^ {{(WIDTH - 1){1'b0}}, inject_fault};

    // ---- the reference: one level a cycle; the stimulus bits of level l delayed l cycles ----
    logic [WIDTH-1:0] reference [LEVELS + 1];
    logic [lab_pkg::STIMULUS_W-1:0] s_delay [LEVELS + 1];
    always_ff @(posedge clk) begin
        logic [WIDTH-1:0] a, b, c;
        reference[0] <= stimulus_bits(s_q, 0);
        s_delay[0]   <= s_q;
        for (int l = 0; l < LEVELS; l++) begin
            s_delay[l + 1] <= s_delay[l];
            a = stimulus_bits(s_delay[l], 3 * l + 1);
            b = stimulus_bits(s_delay[l], 3 * l + 2);
            c = stimulus_bits(s_delay[l], 3 * l + 3);
            for (int w = 0; w < WIDTH; w++) reference[l + 1][w] <= level(l, reference[l][w], a[w], b[w], c[w]);
        end
    end

    // the device's result against the reference: the device is one register after the
    // stimulus, the reference LEVELS, so the device's result is delayed LEVELS - 1 more
    logic [WIDTH-1:0] device_delay [LEVELS];
    always_ff @(posedge clk) begin
        device_delay[0] <= device_q;
        for (int l = 0; l + 1 < LEVELS; l++) device_delay[l + 1] <= device_delay[l];
    end

    // both sides are valid once the pipelines have filled
    logic [7:0] warm;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            warm     <= '0;
            mismatch <= 1'b0;
        end else begin
            if (warm != 8'd255) warm <= warm + 8'd1;
            mismatch <= warm == 8'd255 && device_delay[LEVELS - 1] != reference[LEVELS];
        end
    end

endmodule
`default_nettype wire
