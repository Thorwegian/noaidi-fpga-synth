//------------------------------------------------------------------------
// dsp_probe.sv -- what nextpnr makes of MULTADDALU18X18 at 73.728 MHz (#138)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Self-driving on purpose: three pins, everything else internal, so the
// path nextpnr reports is the one we care about and not an IO delay.
// Shaped like the real CSP MAC step rather than a toy --
//
//     data memory read  ->  DSP multiply-accumulate  ->  data memory write
//
// with a 512x18 memory like the CSP's and the immediate changing every
// cycle, as it would coming out of instruction memory.
//
// Two variants:
//   ACC_IN_DSP=1  the accumulator is the DSP's OWN output register.
//                 A running accumulator needs it: with OUT_REG bypassed
//                 there is nothing inside the block for ACCLOAD to
//                 accumulate into.
//   ACC_IN_DSP=0  fully combinational, C driven from a fabric register --
//                 measures what putting the loop through fabric costs.
//------------------------------------------------------------------------
`default_nettype none
module dsp_probe #(
    parameter bit ACC_IN_DSP = 1'b1
) (
    input  wire       sysclk,
    input  wire       rst,
    output wire [0:0] led
);
    wire clk   = sysclk;
    wire rst_n = ~rst;

    logic [17:0] ctr;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) ctr <= 18'd0;
        else        ctr <= ctr + 18'd1;

    wire [8:0]  rd_addr = ctr[8:0];
    wire [8:0]  wr_addr = ctr[17:9];
    wire [17:0] imm     = {ctr[8:0], ctr[17:9]};
    wire        accload = ctr[0];
    wire        we      = ctr[1];

    reg signed [17:0] dmem [0:511];
    logic signed [17:0] dmem_q;
    integer i;
    initial for (i = 0; i < 512; i = i + 1) dmem[i] = 18'sd0;
    always_ff @(posedge clk) dmem_q <= dmem[rd_addr];

    wire [53:0] mac_out;
    wire [53:0] c_in;

    generate
    if (ACC_IN_DSP) begin : g_dsp_acc
        assign c_in = 54'd0;
        MULTADDALU18X18 #(
            .A0REG(1'b0), .B0REG(1'b0), .A1REG(1'b0), .B1REG(1'b0),
            .CREG(1'b0), .PIPE0_REG(1'b0), .PIPE1_REG(1'b0),
            .OUT_REG(1'b1)
        ) u_mac (
            .A0(dmem_q), .B0(imm), .A1(18'sd0), .B1(18'sd0),
            .C(c_in), .SIA(18'd0), .SIB(18'd0), .CASI(55'd0),
            .ASIGN(2'b11), .BSIGN(2'b11), .ASEL(2'b00), .BSEL(2'b00),
            .CE(1'b1), .CLK(clk), .RESET(rst), .ACCLOAD(accload),
            .DOUT(mac_out), .CASO(), .SOA(), .SOB()
        );
    end else begin : g_fabric_acc
        logic [53:0] acc_r;
        always_ff @(posedge clk or negedge rst_n)
            if (!rst_n)       acc_r <= 54'd0;
            else if (accload) acc_r <= mac_out;
            else              acc_r <= 54'd0;
        assign c_in = acc_r;
        MULTADDALU18X18 #(
            .A0REG(1'b0), .B0REG(1'b0), .A1REG(1'b0), .B1REG(1'b0),
            .CREG(1'b0), .PIPE0_REG(1'b0), .PIPE1_REG(1'b0),
            .OUT_REG(1'b0)
        ) u_mac (
            .A0(dmem_q), .B0(imm), .A1(18'sd0), .B1(18'sd0),
            .C(c_in), .SIA(18'd0), .SIB(18'd0), .CASI(55'd0),
            .ASIGN(2'b11), .BSIGN(2'b11), .ASEL(2'b00), .BSEL(2'b00),
            .CE(1'b1), .CLK(clk), .RESET(rst), .ACCLOAD(accload),
            .DOUT(mac_out), .CASO(), .SOA(), .SOB()
        );
    end
    endgenerate

    // Q8.28 -> Q4.14 on the way back, as a store would
    always_ff @(posedge clk)
        if (we) dmem[wr_addr] <= mac_out[31:14];

    assign led[0] = ^dmem_q ^ mac_out[53];
endmodule
`default_nettype wire
