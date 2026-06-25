module delta_sigma_2nd_order_robust #(
    parameter BITS = 10
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire [BITS-1:0] data_in,
    output wire            pdm_out
);

    // Ved å bruke BITS + 4, gir du integratorene nok "luft" til å 
    // håndtere selv de mest aggressive trekantbølgene uten wrapping.
    reg [BITS+3:0] acc1;
    reg [BITS+3:0] acc2;

    // Ved 0 dBFS skal feedback matche fullskala inngangssignal.
    // Vi bruker MSB fra acc2 som pdm_out, og skalerer feedback 
    // til å tilsvare "fullt påslag" (2^BITS).
    assign pdm_out = acc2[BITS+3];

    wire [BITS+3:0] feedback = {pdm_out, {BITS{1'b0}}};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc1 <= 0;
            acc2 <= 0;
        end else begin
            // Ingen metning, ingen skalering – bare rå matematikk.
            // Siden vi har 4 ekstra bits, vil ikke wrapping forekomme.
            acc1 <= acc1 + data_in - feedback;
            acc2 <= acc2 + acc1    - feedback;
        end
    end

endmodule
