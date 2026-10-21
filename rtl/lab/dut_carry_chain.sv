//------------------------------------------------------------------------
// dut_carry_chain.sv — a device under test: a BITS-bit addition in one cycle
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The device adds two BITS-bit operands from the stimulus in one cycle, the
// carry chain's whole length. The reference adds them 18 bits a cycle with
// the carry registered between slices, which is a chain the first revision
// ran at 73.728 MHz with room, and the device's sum is delayed to meet it.
// A cycle in which they differ is a mismatch.
//------------------------------------------------------------------------
`default_nettype none
module dut_carry_chain #(
    parameter int BITS = 54
) (
    input  wire                              clk,
    input  wire                              reset_n,
    input  wire [lab_pkg::STIMULUS_W-1:0]    stimulus,
    input  wire                              inject_fault,
    output logic                             mismatch
);

    localparam int SLICE  = 18;
    localparam int SLICES = (BITS + SLICE - 1) / SLICE;
    localparam int PADDED = SLICES * SLICE;

    // the operands: BITS bits each out of the stimulus, registered once for both sides
    logic [PADDED-1:0] a_q, b_q;
    always_ff @(posedge clk) begin
        a_q <= PADDED'(stimulus[BITS-1:0]);
        b_q <= PADDED'(stimulus[lab_pkg::STIMULUS_W-1 -: BITS]);
    end

    // ---- the device: the whole addition in one cycle ----
    logic [PADDED:0] device_q;
    always_ff @(posedge clk) device_q <= ({1'b0, a_q} + {1'b0, b_q}) ^ {{PADDED{1'b0}}, inject_fault};

    // ---- the reference: a slice a cycle, the carry registered ----
    logic [PADDED-1:0] a_slices [SLICES + 1];
    logic [PADDED-1:0] b_slices [SLICES + 1];
    logic [PADDED-1:0] sum_slices [SLICES + 1];
    logic              carry [SLICES + 1];
    always_ff @(posedge clk) begin
        a_slices[0]   <= a_q;
        b_slices[0]   <= b_q;
        sum_slices[0] <= '0;
        carry[0]      <= 1'b0;
        for (int s = 0; s < SLICES; s++) begin
            logic [SLICE:0] partial;
            partial = {1'b0, a_slices[s][s * SLICE +: SLICE]} + {1'b0, b_slices[s][s * SLICE +: SLICE]} + {{SLICE{1'b0}}, carry[s]};
            a_slices[s + 1]   <= a_slices[s];
            b_slices[s + 1]   <= b_slices[s];
            sum_slices[s + 1] <= sum_slices[s] | (PADDED'(partial[SLICE-1:0]) << (s * SLICE));
            carry[s + 1]      <= partial[SLICE];
        end
    end

    // the device's sum against the reference's sum and carry: the device is one register
    // after the operands, the reference SLICES, so the device's sum is delayed SLICES - 1 more
    logic [PADDED:0] device_delay [SLICES];
    always_ff @(posedge clk) begin
        device_delay[0] <= device_q;
        for (int s = 0; s + 1 < SLICES; s++) device_delay[s + 1] <= device_delay[s];
    end

    logic [7:0] warm;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            warm     <= '0;
            mismatch <= 1'b0;
        end else begin
            if (warm != 8'd255) warm <= warm + 8'd1;
            mismatch <= warm == 8'd255 && device_delay[SLICES - 1] != {carry[SLICES], sum_slices[SLICES]};
        end
    end

endmodule
`default_nettype wire
