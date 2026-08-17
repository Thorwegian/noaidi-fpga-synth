//--------------------------------------------------------------------
// svf.sv — Chamberlin State-Variable Filter
//--------------------------------------------------------------------

// CERN-OHL-S v2
`default_nettype none
module svf (
    input  logic                    strobe,
    input  logic                    rst_n,
    input  logic signed [17:0]      sample_in,  // Q2.16 format
    input  logic        [13:0]      fc_in,      // Octave and pitch in Q4.10 format
    input  logic        [35:0]      q1_in,      // 1/Q in Q8.28 format
    output logic signed [17:0]      lp_out,
    output logic signed [17:0]      bp_out,
    output logic signed [17:0]      hp_out
);

    logic [15:0] k_lut[1024];

    logic signed [35:0] ic1eq, ic2eq; // Q8.28

    // TODO: Limit fc_in to 0..11093 to avoid K overflow (i.e. fc_in > 11093 will cause K > 1.0, which is not supported by the filter)
    logic [3:0] oct = fc_in[13:10];
    logic [9:0] idx = fc_in[9:0];
    logic [35:0] k = k_lut[idx] <<< (3 + oct);

    initial begin
        $readmemh("svf_k_lut.hex", k_lut);
    end

    logic signed [71:0] kXic1eq;
    MULT36X36 u_kXic1eq(
        .DOUT(kXic1eq),
        .A(k),
        .B(ic1eq),
        .ASIGN(1'b0),
        .BSIGN(1'b1),
        .CE(0),
        .CLK(0),
        .RESET(!rst_n)
    );

    logic signed [71:0] q1Xic1eq;
    MULT36X36 u_q1Xic1eq(
        .DOUT(q1Xic1eq),
        .A(q1_in),
        .B(ic1eq),
        .ASIGN(1'b0),
        .BSIGN(1'b1),
        .CE(0),
        .CLK(0),
        .RESET(!rst_n)
    );

    logic signed [71:0] kXhp;
    MULT36X36 u_kXhp(
        .DOUT(kXhp),
        .A(k),
        .B(hp),
        .ASIGN(1'b0),
        .BSIGN(1'b1),
        .CE(0),
        .CLK(0),
        .RESET(!rst_n)
    );

    logic signed [35:0] lp = ic2eq + (kXic1eq >>> 28);
    logic signed [35:0] hp = (sample_in <<< 18) - lp - (q1Xic1eq >>> 28);
    logic signed [35:0] bp = (kXhp >>> 28) + ic1eq;

    always @(posedge strobe or negedge rst_n) begin
        if(!rst_n) begin
            ic1eq <= 0;
            ic2eq <= 0;
        end else begin
            ic1eq <= bp;
            ic2eq <= lp;
            lp_out <= lp >>> 18;
            bp_out <= bp >>> 18;
            hp_out <= hp >>> 18;
        end
    end

endmodule
