module i2s_tx #(
    parameter BITS = 24
) (
    input sck,
    input ws,

    // Change both while data_ready is high
    input [BITS-1:0] data_left,
    input [BITS-1:0] data_right,
    output data_ready,

    output sd
);

reg wsd, wsd_d1;
reg [BITS-1:0] shift_register;

// 1. Two D-flip-flops driven on the rising edge of SCK (per the CLK line in the diagram)
always @(posedge sck) begin
    wsd    <= ws;
    wsd_d1 <= wsd;
end

assign data_ready = wsd & wsd_d1;

// 2. XOR gate generating the parallel load strobe (WSP)
wire wsp = wsd ^ wsd_d1;

// 3. Shift register driven on the falling edge (~SCK via the inverter)
always @(negedge sck) begin
    if (wsp) begin
        // Synchronous parallel loading (PL) governed by OE multiplexing (WSD)
        shift_register <= wsd ? data_right : data_left;
    end else begin
        // Shift in a zero from the LSB side every standard clock cycle
        shift_register <= {shift_register[BITS-2:0], 1'b0};
    end
end

// 4. The most significant bit (MSB) is permanently tied directly to the output pin
assign sd = shift_register[BITS-1];

endmodule