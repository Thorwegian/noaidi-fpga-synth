//------------------------------------------------------------------------
// dut_dsp.sv — a device under test: a MULTALU36X18's multiply and add in one clock
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The device is one MULTALU36X18 in the configuration the multiply-add unit
// uses (rtl/csp/csp_multiply_add.sv): a × b + c with an 18-bit a, a 36-bit b
// and a 54-bit c, signed, from the stimulus, with AREG, BREG, CREG and
// OUT_REG on and PIPE_REG off, so the 18 × 36 product and the 54-bit add are
// one clock inside the block, from its input registers to its output
// register. With PIPE the pipeline register is on as well and the block is
// two clocks, one of multiplying and one of adding. The pipeline register
// (REGP0 and REGP1 in UG287-1.4E p29, figure 4-9) sits between the
// multipliers and the ALU while C has REGC alone, so with PIPE the device
// holds c one more cycle in the fabric for REGC to meet the product behind
// the pipeline register. The operand registers go to the block's pins with
// no logic between, and the block's output goes into a fabric register and
// nowhere else: what the device measures is the block's own path.
//
// The reference is the textbook carry-save array multiplier: a row per bit
// of a, each adding one partial product (b sign-extended and shifted up by
// the bit's weight, where the bit is set) into a sum vector and a carry
// vector with a full adder per bit. A full adder's sum and carry are each a
// function of three inputs, four with the partial product's AND folded in,
// so a row is one LUT4 between registers and no carry chain. The rows start
// from c as the sum vector; a's sign bit, whose weight is −2^17, adds ~b
// shifted up 17 with a one at 2^17 in the carry vector the rows start from,
// the two's complement of b << 17. After the rows the two vectors are added
// 18 bits a cycle with the carry registered between slices, as the
// carry-chain device's reference adds. Everything wraps at 54 bits, as the
// block does. The device's result is delayed to meet the reference; a cycle
// in which they differ is a mismatch, found one LUT4 a cycle as well (the
// bits' differences registered, then OR'd four at a time), so that no
// fabric path but the block's own is longer than the reference's.
//
// In simulation a behavioural model with the block's latency stands in, the
// one rtl/csp/csp_multiply_add.sv has, registering the product before the
// add when PIPE.
//------------------------------------------------------------------------
`default_nettype none
module dut_dsp #(
    parameter int PIPE = 0                   // 1: the pipeline register on, the product registered before the add
) (
    input  wire                              clk,
    input  wire                              reset_n,
    input  wire [lab_pkg::STIMULUS_W-1:0]    stimulus,
    input  wire                              inject_fault,     // simulation: corrupt the device's result
    output logic                             mismatch
);

    localparam int A_W   = 18;               // the block's operands and sum: UG287-1.4E p30, table 4-9
    localparam int B_W   = 36;
    localparam int SUM_W = 54;

    localparam int ROWS     = A_W;           // the reference: a row per bit of a …
    localparam int SIGN_ROW = A_W - 1;
    localparam int SLICE    = 18;            // … then the carry-propagate add, a slice a cycle
    localparam int SLICES   = SUM_W / SLICE;

    // registers from the operand registers to each side's result: the reference copies the
    // operands, then a row a cycle and a slice a cycle; the block is AREG, PIPE_REG when on
    // and OUT_REG, then the fabric register its output goes into
    localparam int REFERENCE_LATENCY = 1 + ROWS + SLICES;
    localparam int DEVICE_LATENCY    = 3 + PIPE;
    localparam int DEVICE_DELAY      = REFERENCE_LATENCY - DEVICE_LATENCY;

    // the operands, registered once for both sides: 108 bits out of a 96-bit stimulus, so
    // c's low bits are the stimulus's low bits again, as the LUT chains wrap their indices
    localparam int C_HIGH_W = lab_pkg::STIMULUS_W - A_W - B_W;
    localparam int C_LOW_W  = SUM_W - C_HIGH_W;
    logic signed [A_W-1:0]   a_q;
    logic signed [B_W-1:0]   b_q;
    logic signed [SUM_W-1:0] c_q;
    always_ff @(posedge clk) begin
        a_q <= stimulus[0 +: A_W];
        b_q <= stimulus[A_W +: B_W];
        c_q <= {stimulus[A_W + B_W +: C_HIGH_W], stimulus[0 +: C_LOW_W]};
    end

    // ---- the device: the block with its registers on, between the operand registers and a fabric register ----

    // c on the block's C pin: held a cycle when PIPE, for REGC to meet the pipeline register
    logic signed [SUM_W-1:0] c_pin;
    if (PIPE != 0) begin : g_c_held
        always_ff @(posedge clk) c_pin <= c_q;
    end else begin : g_c_direct
        assign c_pin = c_q;
    end

    logic [SUM_W-1:0] block_out;
`ifdef SYNTHESIS
    wire [SUM_W:0] cascade_unused;

    MULTALU36X18 #(                          // the parameters: UG287-1.4E p30 and p31, table 4-10
        .AREG              (1'b1),
        .BREG              (1'b1),
        .CREG              (1'b1),
        .ASIGN_REG         (1'b0),
        .BSIGN_REG         (1'b0),
        .ACCLOAD_REG0      (1'b0),
        .ACCLOAD_REG1      (1'b0),
        .OUT_REG           (1'b1),
        .PIPE_REG          (PIPE != 0 ? 1'b1 : 1'b0),
        .C_ADD_SUB         (1'b0),           // add c
        .MULTALU36X18_MODE (0),              // a × b ± c
        .MULT_RESET_MODE   ("SYNC")
    ) u_block (
        .A       (a_q),
        .B       (b_q),
        .C       (c_pin),
        .ASIGN   (1'b1),
        .BSIGN   (1'b1),
        .ACCLOAD (1'b0),
        .CASI    ({(SUM_W + 1){1'b0}}),
        .CLK     (clk),
        .CE      (1'b1),
        .RESET   (1'b0),                     // nothing in the block needs a reset: the warm-up outlasts its pipeline
        .DOUT    (block_out),
        .CASO    (cascade_unused)
    );
`else
    // the model: the block's input registers, the product registered before the add when PIPE
    logic signed [A_W-1:0]   a_r;
    logic signed [B_W-1:0]   b_r;
    logic signed [SUM_W-1:0] c_r;
    always_ff @(posedge clk) begin
        a_r <= a_q;
        b_r <= b_q;
        c_r <= c_pin;
    end
    if (PIPE != 0) begin : g_piped
        logic signed [SUM_W-1:0] product_r;
        always_ff @(posedge clk) begin
            product_r <= SUM_W'(a_r) * SUM_W'(b_r);
            block_out <= product_r + c_r;                     // wraps at 54 bits, as the block does
        end
    end else begin : g_unpiped
        always_ff @(posedge clk) block_out <= (SUM_W'(a_r) * SUM_W'(b_r)) + c_r;
    end
`endif

    // the block's output into the fabric, where the bench's fault is applied
    logic [SUM_W-1:0] device_q;
    always_ff @(posedge clk) device_q <= block_out ^ {{(SUM_W - 1){1'b0}}, inject_fault};

    // ---- the reference: the carry-save rows, then the carry-propagate add a slice a cycle ----

    // row i's partial product: b sign-extended and shifted up i, where a's bit i is set; the sign
    // row's is ~b, the two's complement of b << 17 completed by the one the carry vector starts with
    function automatic logic [SUM_W-1:0] partial_product(input logic [B_W-1:0] b_in, input logic a_bit, input int row);
        logic signed [SUM_W-1:0] extended;
        extended        = SUM_W'(signed'(b_in ^ {B_W{row == SIGN_ROW}}));
        partial_product = a_bit ? (extended << row) : '0;
    endfunction

    // the full adders' carries, a bit at a time
    function automatic logic [SUM_W-1:0] majority(input logic [SUM_W-1:0] x, input logic [SUM_W-1:0] y, input logic [SUM_W-1:0] z);
        majority = (x & y) | (x & z) | (y & z);
    endfunction

    // the vectors: [0] the operands copied, [i + 1] after row i, then carried along the slices
    logic [A_W-1:0]   a_row [ROWS + 1];
    logic [B_W-1:0]   b_row [ROWS + 1];
    logic [SUM_W-1:0] sum_vector    [ROWS + SLICES + 1];
    logic [SUM_W-1:0] carry_vector  [ROWS + SLICES + 1];
    logic [SUM_W-1:0] result_slices [SLICES + 1];
    logic             slice_carry   [SLICES + 1];
    always_ff @(posedge clk) begin
        a_row[0]        <= a_q;
        b_row[0]        <= b_q;
        sum_vector[0]   <= c_q;
        carry_vector[0] <= SUM_W'(a_q[SIGN_ROW]) << SIGN_ROW;
        for (int i = 0; i < ROWS; i++) begin
            logic [SUM_W-1:0] partial;
            partial = partial_product(b_row[i], a_row[i][i], i);
            a_row[i + 1]        <= a_row[i];
            b_row[i + 1]        <= b_row[i];
            sum_vector[i + 1]   <= partial ^ sum_vector[i] ^ carry_vector[i];
            carry_vector[i + 1] <= majority(partial, sum_vector[i], carry_vector[i]) << 1;
        end
        result_slices[0] <= '0;
        slice_carry[0]   <= 1'b0;
        for (int s = 0; s < SLICES; s++) begin
            logic [SLICE:0] slice_sum;
            slice_sum = {1'b0, sum_vector[ROWS + s][s * SLICE +: SLICE]} + {1'b0, carry_vector[ROWS + s][s * SLICE +: SLICE]} + {{SLICE{1'b0}}, slice_carry[s]};
            sum_vector[ROWS + s + 1]   <= sum_vector[ROWS + s];
            carry_vector[ROWS + s + 1] <= carry_vector[ROWS + s];
            result_slices[s + 1]       <= result_slices[s] | (SUM_W'(slice_sum[SLICE-1:0]) << (s * SLICE));
            slice_carry[s + 1]         <= slice_sum[SLICE];
        end
    end

    // the device's result against the reference's: delayed from device_q to meet the last slice
    logic [SUM_W-1:0] device_delay [DEVICE_DELAY];
    always_ff @(posedge clk) begin
        device_delay[0] <= device_q;
        for (int d = 0; d + 1 < DEVICE_DELAY; d++) device_delay[d + 1] <= device_delay[d];
    end

    // the comparison one LUT4 a cycle as well, so that no fabric path but the block's own is longer
    // than the reference's: the bits that differ, then OR'd four at a time down to one
    function automatic logic [SUM_W-1:0] or_by_four(input logic [SUM_W-1:0] bits);
        or_by_four = '0;
        for (int k = 0; k < SUM_W; k++) or_by_four[k / 4] = or_by_four[k / 4] | bits[k];
    endfunction

    localparam int DIFFER_LEVELS = 4;                    // 54 bits, then 14, 4 and 1
    logic [SUM_W-1:0] differ [DIFFER_LEVELS];
    always_ff @(posedge clk) begin
        differ[0] <= device_delay[DEVICE_DELAY - 1] ^ result_slices[SLICES];
        for (int l = 0; l + 1 < DIFFER_LEVELS; l++) differ[l + 1] <= or_by_four(differ[l]);
    end

    // both sides are valid once the pipelines have filled
    logic [7:0] warm;
    logic       settled;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            warm     <= '0;
            settled  <= 1'b0;
            mismatch <= 1'b0;
        end else begin
            if (warm != 8'd255) warm <= warm + 8'd1;
            settled  <= warm == 8'd255;
            mismatch <= settled && differ[DIFFER_LEVELS - 1][0];
        end
    end

endmodule
`default_nettype wire
