//------------------------------------------------------------------------
// reg_banks.sv — register bank decoder layered ON TOP of spi_slave
//
// Does NOT touch the SPI transceiver (proven in hardware).  Consumes
// spi_slave's `done`/`received_data` handshake:
//
//     done is a single SCLK pulse, coincident with received_data being a
//     new valid byte.  (Confirmed: send 0xAA -> received_data=0xAA.)
//
// Protocol (matches app/main/spi_regs.c, single-byte registers):
//     byte 1 = command: [7]=R/W (0=write), [3:0]=address, [6:4]=reserved
//     byte 2 = data    (ignored if command was a read)
//
// On command byte: latch addr + rw.  On data byte of a write: store the
// data (zero-extended) into mem[addr].  Writes are in the SPI (sclk)
// domain; reads are in the sysclk domain — the BSRAM IS the CDC.
//------------------------------------------------------------------------
`default_nettype none
module reg_banks #(
    parameter int NWORDS = 16
) (
    input  logic        sclk,
    input  logic        cs,
    input  logic [7:0]  rx_byte,   // spi_slave.received_data
    input  logic        rx_done,   // spi_slave.done (single-cycle pulse)

    input  logic        sysclk,
    input  logic        rst_n,
    input  logic [3:0]  read_addr,
    output logic [35:0] read_data
);

    // ---- register store (dual-clock dual-port BSRAM) ------------------
    reg [35:0] mem [0:NWORDS-1];
    integer i0;
    initial for (i0 = 0; i0 < NWORDS; i0++) mem[i0] = '0;

    // ---- decode byte stream (sclk domain) -----------------------------
    logic       expect_data;  // 1 = next byte is data, 0 = next is command
    logic       rw;
    logic [3:0] addr;

    always_ff @(posedge sclk or posedge cs) begin
        if (cs) begin
            expect_data <= 1'b0;
            rw          <= 1'b0;
            addr        <= 4'd0;
        end else if (rx_done) begin
            if (!expect_data) begin
                // command byte
                addr        <= rx_byte[3:0];
                rw          <= rx_byte[7];
                expect_data <= 1'b1;
            end else begin
                // data byte
                if (!rw)
                    mem[addr] <= {28'd0, rx_byte};
                expect_data <= 1'b0;
            end
        end
    end

    // ---- read port (sysclk domain) ------------------------------------
    always_ff @(posedge sysclk) begin
        if (!rst_n)
            read_data <= '0;
        else
            read_data <= mem[read_addr];
    end

endmodule
