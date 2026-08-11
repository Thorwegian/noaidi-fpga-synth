`default_nettype none
module voice (
    input  logic         rst_n,
    input  logic         strobe,             // Sample strobe
    
    input  logic [13:0]  pitch_in,           // UQ4.10 format
    input  logic [13:0]  cutoff_in,          // UQ4.10 format
    
    output logic signed [17:0] sample_out   // Q2.16 format
);

    logic [6:0][13:0] ssaw_pitches;
    always @(posedge strobe) begin
        for (int i = 0; i < 7; i++) begin
            ssaw_pitches[i] = pitch_in + ((i - 3) * 14'sd32);
        end
    end
    logic signed [6:0][23:0] ssaw_oscs;
    for (genvar i = 0; i < 7; i++) begin
        osc_bank #(.PHASE(i * 24'sd2396745)) u_ssaw (
            .strobe (strobe),
            .pitch  (ssaw_pitches[i]),
            .duty    (24'sd0),
            .out_saw (ssaw_oscs[i]),
            .out_pul (),
            .out_tri (),
            .out_sin ()
        );
    end

    logic signed [17:0] ssaw_sum;
    always @(posedge strobe) begin
        ssaw_sum = 18'sd0;
        for (int i = 0; i < 7; i++) begin
            ssaw_sum += ssaw_oscs[i] / (8 * 256); // Scale Q0.24 → Q2.16 and divide by 8
        end
    end

    svf u_svf (
        .rst_n      (rst_n),
        .strobe     (strobe),
        .sample_in  (ssaw_sum),
        .fc_in      (cutoff_in),
        .q1_in      (36'h10000000),
        .lp_out     (sample_out),
        .bp_out     (),
        .hp_out     ()
    );

    //assign sample_out = ssaw_sum;
endmodule