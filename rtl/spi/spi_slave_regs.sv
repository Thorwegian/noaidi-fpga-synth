// SPDX-License-Identifier: MIT
// spi_slave_regs.sv — SPI slave with register file interface (v5)
//
// SPI Mode 0 (CPOL=0, CPHA=0): MOSI sampled on rising SCLK,
// MISO driven on falling SCLK.  MSB-first.
//
// CS_N is sampled with edge detection: a falling edge resets state;
// subsequent posedges while CS_N stays low run the transaction.
//
// Protocol:
//   Byte 0:  [DATA_WIDTH-1] = R/W (1=read, 0=write)
//            [ADDR_WIDTH-1:0] = register address
//   Subsequent bytes: data, address auto-increments.
//   Reads: first response byte is status (0x00); register data
//          starts at response byte 2.
//
// CDC:
//   Writes: toggle synchroniser  (SPI → sysclk)
//   Reads:  2-FF address → sysclk, 2-FF data → SPI
`default_nettype none
module spi_slave_regs #(
    parameter ADDR_WIDTH = 7,
    parameter DATA_WIDTH = 8
)(
    input  wire                       i_sclk,
    input  wire                       i_cs_n,
    input  wire                       i_mosi,
    output wire                       o_miso,

    input  wire                       i_sysclk,
    input  wire                       i_rstn,

    output reg                        o_reg_we,
    output reg  [ADDR_WIDTH-1:0]      o_reg_addr,
    output reg  [DATA_WIDTH-1:0]      o_reg_wdata,
    input  wire [DATA_WIDTH-1:0]      i_reg_rdata
);

    localparam BITCNT_W = $clog2(DATA_WIDTH);

    // ── CS_N edge detector ──────────────────────────────────────────
    reg  cs_n_d;   // previous CS_N (posedge domain)
    wire cs_falling = !i_cs_n && cs_n_d;   // 1→0 transition

    // ── SPI domain state ────────────────────────────────────────────
    reg  [DATA_WIDTH-1:0]  shreg_rx;
    reg  [DATA_WIDTH-1:0]  shreg_tx;
    reg  [BITCNT_W-1:0]    bitcnt;
    reg                    cmd_phase;
    reg                    rw_flag;
    reg  [ADDR_WIDTH-1:0]  addr;

    reg  miso_q;
    assign o_miso = miso_q;

    // ── POSEDGE: sample MOSI, state machine ─────────────────────────
    always @(posedge i_sclk) begin
        cs_n_d <= i_cs_n;   // track for next edge

        if (cs_falling) begin
            // ── CS_N just asserted: reset for new transaction ───
            shreg_rx      <= {DATA_WIDTH{1'b0}};
            shreg_tx      <= {DATA_WIDTH{1'b0}};
            bitcnt        <= DATA_WIDTH - 1;
            cmd_phase     <= 1'b0;
            rw_flag       <= 1'b0;
            addr          <= {ADDR_WIDTH{1'b0}};
            read_addr_spi <= {ADDR_WIDTH{1'b0}};
            rdata_sync0   <= {DATA_WIDTH{1'b0}};
            rdata_sync1   <= {DATA_WIDTH{1'b0}};
            wr_toggle_spi <= 1'b0;
        end else if (!i_cs_n) begin
            // ── Transaction in progress ─────────────────────────

            // Continuously sync read data from sysclk domain
            rdata_sync0 <= i_reg_rdata;
            rdata_sync1 <= rdata_sync0;

            // Shift in MOSI (MSB-first, LSB side)
            shreg_rx <= {shreg_rx[DATA_WIDTH-2:0], i_mosi};

            if (bitcnt == 0) begin
                // Byte complete.  shreg_rx just captured the 8th bit
                // (NBA ordering means the OLD shreg_rx had 7 bits;
                //  build the full byte explicitly for decoding.)
                reg [DATA_WIDTH-1:0] rx_byte;
                rx_byte = {shreg_rx[DATA_WIDTH-2:0], i_mosi};

                if (!cmd_phase) begin
                    // Command byte
                    rw_flag   <= rx_byte[DATA_WIDTH-1];
                    addr      <= rx_byte[ADDR_WIDTH-1:0];
                    cmd_phase <= 1'b1;
                    shreg_tx  <= {DATA_WIDTH{1'b0}};   // status byte (0x00)
                    if (rx_byte[DATA_WIDTH-1])
                        read_addr_spi <= rx_byte[ADDR_WIDTH-1:0];
                end else begin
                    if (!rw_flag) begin
                        shreg_tx      <= {DATA_WIDTH{1'b0}};
                        wr_addr_spi   <= addr;
                        wr_data_spi   <= rx_byte;
                        wr_toggle_spi <= ~wr_toggle_spi;
                    end else begin
                        shreg_tx      <= rdata_spi_sync;
                        read_addr_spi <= addr + 1;
                    end
                    addr <= addr + 1;
                end
                bitcnt <= DATA_WIDTH - 1;
            end else begin
                bitcnt <= bitcnt - 1;
            end
        end else begin
            // ── CS_N high: idle ─────────────────────────────────
            shreg_rx      <= {DATA_WIDTH{1'b0}};
            shreg_tx      <= {DATA_WIDTH{1'b0}};
            bitcnt        <= DATA_WIDTH - 1;
            cmd_phase     <= 1'b0;
            rw_flag       <= 1'b0;
            addr          <= {ADDR_WIDTH{1'b0}};
            read_addr_spi <= {ADDR_WIDTH{1'b0}};
            rdata_sync0   <= {DATA_WIDTH{1'b0}};
            rdata_sync1   <= {DATA_WIDTH{1'b0}};
            wr_toggle_spi <= 1'b0;
        end
    end

    // ── NEGEDGE: drive MISO, shift TX ───────────────────────────────
    always @(negedge i_sclk) begin
        if (!i_cs_n) begin
            miso_q   <= shreg_tx[DATA_WIDTH-1];
            shreg_tx <= {shreg_tx[DATA_WIDTH-2:0], 1'b0};
        end else begin
            miso_q   <= 1'b0;
        end
    end

    // ── Write CDC: toggle synchroniser (SPI → sysclk) ──────────────
    reg                       wr_toggle_spi;
    reg  [ADDR_WIDTH-1:0]     wr_addr_spi;
    reg  [DATA_WIDTH-1:0]     wr_data_spi;

    // wr_toggle_spi is toggled in the main posedge block (on write data
    // byte boundaries), using rx_byte for the full 8-bit value.

    // ── sysclk domain: sync toggle, edge-detect, commit write ──────
    reg  [1:0]  wr_sync;
    reg         wr_sync_d;

    always @(posedge i_sysclk or negedge i_rstn) begin
        if (!i_rstn) begin
            cs_n_d     <= 1'b1;
            wr_sync    <= 2'b00;
            wr_sync_d  <= 1'b0;
            o_reg_we   <= 1'b0;
            o_reg_addr <= {ADDR_WIDTH{1'b0}};
            o_reg_wdata<= {DATA_WIDTH{1'b0}};
        end else begin
            wr_sync   <= {wr_sync[0], wr_toggle_spi};
            o_reg_we  <= 1'b0;

            if (wr_sync[1] != wr_sync_d) begin
                wr_sync_d  <= wr_sync[1];
                o_reg_we   <= 1'b1;
                o_reg_addr <= wr_addr_spi;
                o_reg_wdata<= wr_data_spi;
            end
        end
    end

    // ── Read CDC ────────────────────────────────────────────────────
    reg  [ADDR_WIDTH-1:0]  read_addr_spi;

    reg  [ADDR_WIDTH-1:0]  raddr_sync0, raddr_sync1;

    always @(posedge i_sysclk or negedge i_rstn) begin
        if (!i_rstn) begin
            raddr_sync0 <= {ADDR_WIDTH{1'b0}};
            raddr_sync1 <= {ADDR_WIDTH{1'b0}};
        end else begin
            raddr_sync0 <= read_addr_spi;
            raddr_sync1 <= raddr_sync0;
        end
    end

    reg  [DATA_WIDTH-1:0]  rdata_sync0, rdata_sync1;
    wire [DATA_WIDTH-1:0]  rdata_spi_sync = rdata_sync0;

endmodule
