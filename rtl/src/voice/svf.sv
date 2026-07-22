//--------------------------------------------------------------------
// svf.sv — Chamberlin State-Variable Filter
//--------------------------------------------------------------------

// CERN-OHL-S v2

module svf (
    input  logic                    strobe,
    input  logic                    rst_n,
    input  logic signed [17:0]      sample_in,
    input  logic        [13:0]      fc_in,
    input  logic        [4:0]       q_in, // TODO: Decide on Q resolution; make Q LUT
    output logic signed [17:0]      lp_out,
    output logic signed [17:0]      bp_out,
    output logic signed [17:0]      hp_out
);

    logic [15:0] k_lut[1024];

    localparam [35:0] q1 = 36'h10000000; // Q1 = 1/1
    logic signed [35:0] d1, d2; // Q8.28

    logic [3:0] oct = fc_in[13:10];
    logic [9:0] idx = fc_in[9:0];
    logic [35:0] f1 = k_lut[idx] <<< (3 + oct);

    initial begin
        $readmemh("svf_k_lut.hex", k_lut);
    end

    logic signed [71:0] f1Xd1;
    MULT36X36 u_f1Xd1(
        .DOUT(f1Xd1),
        .A(f1),
        .B(d1),
        .ASIGN(1'b0),
        .BSIGN(1'b1),
        .CE(1'b1),
        .CLK(strobe),
        .RESET(~rst_n)
    );

    logic signed [71:0] q1Xd1;
    MULT36X36 u_q1Xd1(
        .DOUT(q1Xd1),
        .A(q1),
        .B(d1),
        .ASIGN(1'b0),
        .BSIGN(1'b1),
        .CE(1'b1),
        .CLK(strobe),
        .RESET(~rst_n)
    );

    logic signed [71:0] f1Xhp;
    MULT36X36 u_f1Xhp(
        .DOUT(f1Xhp),
        .A(f1),
        .B(hp),
        .ASIGN(1'b0),
        .BSIGN(1'b1),
        .CE(1'b1),
        .CLK(strobe),
        .RESET(~rst_n)
    );

    logic signed [35:0] lp = d2 + (f1Xd1 >>> 28);
    logic signed [35:0] hp = (sample_in <<< 18) - lp - (q1Xd1 >>> 28);
    logic signed [35:0] bp = (f1Xhp >>> 28) + d1;

    always @(posedge strobe or negedge rst_n) begin
        if (!rst_n) begin
            d1 <= 0;
            d2 <= 0;
            lp_out <= 0;
            bp_out <= 0;
            hp_out <= 0;
        end else begin
            d1 <= bp;
            d2 <= lp;

            lp_out <= lp >>> 18;
            bp_out <= bp >>> 18;
            hp_out <= hp >>> 18;
        end
    end

endmodule