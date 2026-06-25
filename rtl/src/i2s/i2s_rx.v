module i2s_rx #(
    parameter BITS = 24
)(
    input sck,
    input ws,
    input sd,

    // Read both while data_valid is high
    output reg [BITS-1:0] data_left,
    output reg [BITS-1:0] data_right,
    output data_valid
);

// Calculate required counter width at compile time based on BITS
localparam COUNTER_WIDTH = $clog2(BITS + 1);

reg wsd, wsd_d1, wsd_d2;
reg [COUNTER_WIDTH-1:0] bit_cnt;
reg [BITS-1:0] rx_regs;

// 1. Edge detection for WS (rising edge of SCK)
always @(posedge sck) begin
    wsd    <= ws;
    wsd_d1 <= wsd;
    wsd_d2 <= wsd_d1;
end

assign data_valid = ~(wsd | wsd_d2);

// Generation of the Word Select Pulse (WSP)
wire wsp = wsd ^ wsd_d1;

// 2. The counter driven on falling edge of SCK
always @(negedge sck) begin
    if (wsp) begin
        bit_cnt <= {COUNTER_WIDTH{1'b0}}; // Synchronous reset (R)
    end else if (bit_cnt < BITS) begin
        bit_cnt <= bit_cnt + 1'b1;        // Increment enabled
    end
end

// 3. Decoder and individual bit registers (B1 to Bn driven on rising edge)
always @(posedge sck) begin
    if (bit_cnt < BITS) begin
        // Index mapping: MSB (B1) is loaded first, down to LSB (Bn)
        rx_regs[(BITS-1) - bit_cnt] <= sd;
    end
end

// 4. Output channel buffers (Top AND gates triggered by WSP)
always @(posedge sck) begin
    if (wsp) begin
        if (~wsd_d1) begin
            // WSD bar AND WSP: Left channel data update
            data_left <= rx_regs;
        end else begin
            // WSD AND WSP: Right channel data update
            data_right <= rx_regs;
        end
    end
end

endmodule