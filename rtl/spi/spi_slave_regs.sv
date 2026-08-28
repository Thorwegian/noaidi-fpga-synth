//------------------------------------------------------------------------
// spi_slave_regs.sv — SPI slave (Mode 0) + byte-wide register file
//
// Replaces spi_slave.sv + reg_banks.sv.  Those two had one structural
// fault per direction, and both came from the same root cause: the
// transceiver had no notion of a *byte boundary*, so it could neither
// commit a received byte nor load a byte to send at one.
//
//   RX: spi_slave raised `done` on the FALLING edge and reg_banks
//       consumed it on the RISING edge.  A real Mode 0 master's last
//       edge in a transaction is a falling edge, so the rising edge
//       reg_banks needed to commit the *final* byte never happened —
//       every register write was dropped.  (The old testbench clocked
//       negedge-then-posedge per bit, i.e. a falling-edge-first master
//       that does not exist in hardware.  That manufactured the missing
//       edge and hid the bug in simulation.)
//
//   TX: spi_slave loaded its output shift register only on the CS
//       rising edge, then shifted in zeros.  MISO byte 0 carried the
//       constant latched before CS fell; every later byte read back
//       0x00.  A value computed *during* the transaction — mem[addr],
//       a loopback of the received byte — had no load opportunity at
//       all, which is why "a constant byte works, anything else
//       returns 0x00".
//
// Merging the two into one module makes both impossible: the bit
// counter, the protocol decode and both shift registers see the same
// byte boundary, and nothing is handed across a clock edge.
//
// SPI Mode 0 (CPOL=0, CPHA=0), MSB first.  The master drives MOSI on
// the falling edge of SCLK and samples MISO on the rising edge, so the
// slave does the opposite:
//
//     MOSI sampled on the RISING  edge — stable mid-bit, full margin.
//                                        (The old slave sampled on the
//                                        falling edge, racing the
//                                        master's own MOSI transition;
//                                        it worked at 1 MHz only
//                                        because the master's
//                                        clock-to-out delay covered
//                                        the slave's hold time.)
//     MISO driven  on the FALLING edge — settled before the master
//                                        looks at it.
//
// A byte is therefore complete *at* the 8th rising edge, an edge that
// always exists, and the next byte to send is loaded on the falling
// edge immediately after it.
//
// Wire protocol — one CS-framed transaction:
//
//     byte 0        command: [7] 1 = read, 0 = write
//                            [6:0] start address
//     write: byte 1..N       data on MOSI, address auto-increments
//     read:  byte 1..N       mem[addr], mem[addr+1], ... on MISO
//                            (MOSI content ignored)
//
//     MISO byte 0 always returns ID_BYTE — a free link check on every
//     single transaction.  If byte 0 is not ID_BYTE the physical MISO
//     path is broken and nothing downstream is worth debugging.
//
// Clock domains: the register store is written from the SPI (sclk)
// domain and read as whole words by the drum (sysclk) domain.  See the
// note at the read port about what that is and is not safe for.
//------------------------------------------------------------------------
`default_nettype none
module spi_slave_regs #(
    parameter int       NWORDS  = 16,
    parameter int       DATA_W  = 36,      // native BSRAM word
    parameter [7:0]     ID_BYTE = 8'hA5    // returned as MISO byte 0
) (
    // ---- SPI side — clocked by the master's SCLK ----
    input  logic                      sclk,
    input  logic                      cs,        // active low
    input  logic                      mosi,
    output logic                      miso,

    // ---- drum side ----
    input  logic                      sysclk,
    input  logic                      rst_n,
    input  logic [$clog2(NWORDS)-1:0] read_addr,
    output logic [DATA_W-1:0]         read_data
);

    localparam int AW = $clog2(NWORDS);

    //--------------------------------------------------------------------
    // Receive — MOSI sampled on the rising edge of SCLK
    //--------------------------------------------------------------------
    logic [7:0] rx_sh;
    logic [2:0] bit_cnt;

    // The assembled byte is valid *at* the 8th rising edge: rx_sh[6:0]
    // holds bits 7..1 and mosi is carrying bit 0 right now.  Everything
    // downstream keys off this, on this same edge.
    wire [7:0] rx_byte  = {rx_sh[6:0], mosi};
    wire       byte_end = (bit_cnt == 3'd7);

    always_ff @(posedge sclk or posedge cs) begin
        if (cs) begin
            rx_sh   <= 8'd0;
            bit_cnt <= 3'd0;
        end else begin
            rx_sh   <= rx_byte;
            bit_cnt <= bit_cnt + 3'd1;   // wraps to 0 at the 8th edge
        end
    end

    //--------------------------------------------------------------------
    // Protocol decode (sclk domain)
    //--------------------------------------------------------------------
    logic          have_cmd;   // command byte of this transaction consumed
    logic          is_read;
    logic [AW-1:0] addr;

    // Power-up state.  Every reset in this module is `posedge cs`, and at
    // power-up CS is already high — it goes 1->0 for the first transaction,
    // so that edge never occurs and nothing here is ever reset before the
    // first frame.  Gowin FFs come out of configuration at 0, so hardware
    // is fine, but a simulator starts them at X and the first transaction
    // decodes to garbage.  Declaring the power-up state explicitly makes
    // simulation and hardware agree and pins the value gowin_pack encodes,
    // instead of leaving the first frame dependent on vendor defaults.
    initial begin
        rx_sh    = 8'd0;
        bit_cnt  = 3'd0;
        have_cmd = 1'b0;
        is_read  = 1'b0;
        addr     = '0;
    end

    always_ff @(posedge sclk or posedge cs) begin
        if (cs) begin
            have_cmd <= 1'b0;         // CS framing: every transaction
            is_read  <= 1'b0;         // starts at the command byte
        end else if (byte_end) begin
            have_cmd <= 1'b1;
            if (!have_cmd)
                is_read <= rx_byte[7];
        end
    end

    // Address: loaded from the command byte, then auto-incremented after
    // every data byte (bursts).  Deliberately has no reset — `have_cmd`
    // is reset and decides when addr is loaded, so its idle value never
    // matters, and keeping the reset off it keeps the write process
    // below reset-free (see the BSRAM note there).
    //
    // Only the low AW bits of the 7-bit wire address are decoded;
    // firmware must keep addresses < NWORDS or they alias.
    always_ff @(posedge sclk) begin
        if (byte_end)
            addr <= have_cmd ? (addr + 1'b1) : rx_byte[AW-1:0];
    end

    //--------------------------------------------------------------------
    // Register store
    //
    // The write process is sync-only and reset-free on purpose: an async
    // reset in the same always_ff as a memory write blocks BSRAM
    // inference in yosys (see AGENTS.md).  It does not infer BSRAM as
    // written even so — the combinational read on the SPI side and the
    // second read port on sysclk force distributed logic — which is fine
    // at 16 words (16 x 36 = 576 FFs) and is what makes the one-dummy-
    // byte read protocol possible.  See the read-latency note below
    // before growing this into the real 64K-word map.
    //--------------------------------------------------------------------
    logic [DATA_W-1:0] mem [0:NWORDS-1];

    integer i0;
    initial for (i0 = 0; i0 < NWORDS; i0 = i0 + 1) mem[i0] = '0;

    always_ff @(posedge sclk) begin
        if (byte_end && have_cmd && !is_read)
            mem[addr] <= {{(DATA_W-8){1'b0}}, rx_byte};
    end

    //--------------------------------------------------------------------
    // Transmit — MISO driven on the falling edge of SCLK
    //
    // Load timing: bit_cnt wraps to 0 at the 8th rising edge, so the
    // very next falling edge is the byte boundary.  `addr` was latched
    // by that same rising edge, half a bit period earlier, so the
    // combinational mem[addr] read has settled by the time it is loaded.
    // That is what puts the first register byte at MISO index 1, with
    // only the command byte as turnaround.
    //
    // If the store ever becomes true BSRAM (synchronous read), this no
    // longer holds — the read would need its own clock edge, and the
    // protocol grows a second dummy byte, putting data at MISO index 2.
    //--------------------------------------------------------------------
    wire [7:0] tx_byte = have_cmd ? mem[addr][7:0] : ID_BYTE;

    logic [7:0] tx_sh;
    initial tx_sh = ID_BYTE;   // first-ever transaction: no posedge cs yet

    always_ff @(negedge sclk or posedge cs) begin
        if (cs)
            tx_sh <= ID_BYTE;                 // idle preload: bit 7 is on
                                              // MISO the moment CS falls,
                                              // before the first rising edge
        else if (bit_cnt == 3'd0)
            tx_sh <= tx_byte;                 // byte boundary
        else
            tx_sh <= {tx_sh[6:0], 1'b0};
    end

    assign miso = cs ? 1'b0 : tx_sh[7];

    //--------------------------------------------------------------------
    // Read port (sysclk / drum domain)
    //
    // Synchronous reset only — an async one here would be harmless for
    // read_data itself, but keeping the whole file to one convention
    // avoids re-introducing the inference problem by accident.
    //
    // CDC caveat: a word written from the sclk side while sysclk reads
    // it can be sampled torn.  Harmless for the 8-bit values written
    // today (one byte, one write, settled long before it is read), but
    // multi-byte registers will need either a write-then-commit
    // discipline or genuine dual-clock BSRAM.
    //--------------------------------------------------------------------
    always_ff @(posedge sysclk) begin
        if (!rst_n)
            read_data <= '0;
        else
            read_data <= mem[read_addr];
    end

endmodule
`default_nettype wire
