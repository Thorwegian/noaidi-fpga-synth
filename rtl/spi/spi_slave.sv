//--------------------------------------------------------------------
// spi_slave.sv — minimal dummy SPI slave (Mode 0, CPOL=0, CPHA=0)
//
// Always returns the fixed byte 0xA5 on MISO.  No protocol, no
// register file — this is a bring-up/test slave to prove the physical
// SPI link (CS/SCLK/MOSI/MISO) works before adding the register bank.
//
// SPI Mode 0 timing:
//   - MOSI is sampled by the master on the RISING edge of SCLK.
//   - MISO must be STABLE on the rising edge → we update it on the
//     FALLING edge of SCLK.
//   - Data is shifted MSB first.
//
// Everything is clocked directly off SCLK (the SPI clock).  There is
// NO system clock here — this removes the metastability / edge-detector
// problem of sampling SCLK with a free-running clock.
//--------------------------------------------------------------------
`default_nettype none
module spi_slave (
    input  logic sclk,
    input  logic cs,      // active-low chip select
    input  logic mosi,
    output logic miso,

    // optional bring-up outputs (kept for compatibility)
    output logic done,
    output logic [7:0] received_data
);

    localparam DUMMY_BYTE = 8'hA5;

    logic [7:0] shift_out;
    logic [7:0] shift_in;
    logic [2:0] bit_count;

    // -- MISO: combinationally mirror the TX shift register MSB --------
    // Mode 0 (CPOL=0, CPHA=0): the master samples MISO on each RISING
    // edge of SCLK.  So MISO must hold the correct bit *before* the
    // rising edge.  We derive MISO directly from the shift register so
    // that, at CS assert, bit 7 of the dummy byte is immediately valid.
    assign miso = cs ? 1'b0 : shift_out[7];

    // -- Shift on the FALLING edge of SCLK ----------------------------
    // After the master samples a bit on the rising edge, it starts the
    // next bit on the falling edge.  We advance the shift register on
    // the falling edge, so the next bit is stable well before the next
    // rising edge.  CS assert (async) preloads the dummy byte so bit 7
    // is on MISO before the very first rising edge.
    always_ff @(negedge sclk, posedge cs) begin
        if (cs) begin
            shift_out <= DUMMY_BYTE;
            shift_in  <= 8'd0;
            bit_count <= 3'd0;
        end else begin
            shift_in  <= {shift_in[6:0], mosi};
            shift_out <= {shift_out[6:0], 1'b0};

            if (bit_count == 3'd7)
                bit_count <= 3'd0;   // wrap; back-to-back bytes
            else
                bit_count <= bit_count + 1;
        end
    end

    // -- done / received_data (bring-up convenience) ------------------
    always_ff @(negedge sclk, posedge cs) begin
        if (cs)
            done <= 1'b0;
        else begin
            done <= (bit_count == 3'd7);
            if (bit_count == 3'd7)
                received_data <= {shift_in[6:0], mosi};
        end
    end

endmodule