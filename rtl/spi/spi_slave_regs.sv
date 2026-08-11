// SPDX-License-Identifier: MIT
// spi_slave_regs.sv — SPI slave with register file interface (v6)
//
// SPI Mode 0 (CPOL=0, CPHA=0): MOSI sampled on rising SCLK,
// MISO driven on falling SCLK.  MSB-first.
//
// Single-driver architecture: shreg_tx and miso_q are driven only
// from the negedge SCLK block.  The posedge block communicates load
// requests via tx_load / tx_next.
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

    // ── CS_N edge detector (posedge domain) ──────────────────────────
    reg  cs_n_d;
    wire cs_falling = !i_cs_n && cs_n_d;

    // ── SPI RX state (posedge domain) ─────────────────────────────────
    reg  [DATA_WIDTH-1:0]  shreg_rx;
    reg  [BITCNT_W-1:0]    bitcnt;
    reg                    cmd_phase;
    reg                    rw_flag;
    reg  [ADDR_WIDTH-1:0]  addr;

    // ── TX handshake: posedge → negedge ──────────────────────────────
    reg                    tx_load;
    reg  [DATA_WIDTH-1:0]  tx_next;

    // ── Write CDC registers ──────────────────────────────────────────
    reg                       wr_toggle_spi;
    reg  [ADDR_WIDTH-1:0]     wr_addr_spi;
    reg  [DATA_WIDTH-1:0]     wr_data_spi;

    // ── Read CDC registers ───────────────────────────────────────────
    reg  [ADDR_WIDTH-1:0]  read_addr_spi;
    reg  [DATA_WIDTH-1:0]  rdata_sync0, rdata_sync1;
    wire [DATA_WIDTH-1:0]  rdata_spi_sync = rdata_sync0;

    // ── MISO output (negedge domain) ──────────────────────────────────
    reg  [DATA_WIDTH-1:0]  shreg_tx;
    reg                    miso_q;
    assign o_miso = miso_q;

    // ═════════════════════════════════════════════════════════════════
    // POSEDGE: sample MOSI, run RX state machine, request TX loads
    // ═════════════════════════════════════════════════════════════════
    always @(posedge i_sclk or negedge i_rstn) begin
        if (!i_rstn) begin
            cs_n_d     <= 1'b1;
            shreg_rx   <= {DATA_WIDTH{1'b0}};
            bitcnt     <= DATA_WIDTH - 1;
            cmd_phase  <= 1'b0;
            rw_flag    <= 1'b0;
            addr       <= {ADDR_WIDTH{1'b0}};
            tx_load    <= 1'b0;
            tx_next    <= {DATA_WIDTH{1'b0}};
        end else begin
            cs_n_d <= i_cs_n;

            if (cs_falling) begin
                // CS_N just asserted: reset for new transaction
                shreg_rx      <= {DATA_WIDTH{1'b0}};
                bitcnt        <= DATA_WIDTH - 1;
                cmd_phase     <= 1'b0;
                rw_flag       <= 1'b0;
                addr          <= {ADDR_WIDTH{1'b0}};
                read_addr_spi <= {ADDR_WIDTH{1'b0}};
                rdata_sync0   <= {DATA_WIDTH{1'b0}};
                rdata_sync1   <= {DATA_WIDTH{1'b0}};
                wr_toggle_spi <= 1'b0;
                tx_load       <= 1'b0;
            end else if (!i_cs_n) begin
                // ── Transaction in progress ──────────────────────
                rdata_sync0 <= i_reg_rdata;
                rdata_sync1 <= rdata_sync0;
                shreg_rx    <= {shreg_rx[DATA_WIDTH-2:0], i_mosi};

                // Default: no TX load this cycle
                tx_load <= 1'b0;

                if (bitcnt == 0) begin
                    reg [DATA_WIDTH-1:0] rx_byte;
                    rx_byte = {shreg_rx[DATA_WIDTH-2:0], i_mosi};

                    if (!cmd_phase) begin
                        // Command byte
                        rw_flag   <= rx_byte[DATA_WIDTH-1];
                        addr      <= rx_byte[ADDR_WIDTH-1:0];
                        cmd_phase <= 1'b1;
                        // Request status byte (0x00)
                        tx_load   <= 1'b1;
                        tx_next   <= {DATA_WIDTH{1'b0}};
                        if (rx_byte[DATA_WIDTH-1])
                            read_addr_spi <= rx_byte[ADDR_WIDTH-1:0];
                    end else begin
                        if (!rw_flag) begin
                            // Write data byte
                            wr_addr_spi   <= addr;
                            wr_data_spi   <= rx_byte;
                            wr_toggle_spi <= ~wr_toggle_spi;
                            // Keep MISO low
                            tx_load <= 1'b1;
                            tx_next <= {DATA_WIDTH{1'b0}};
                        end else begin
                            // Read data byte
                            tx_load       <= 1'b1;
                            tx_next       <= rdata_spi_sync;
                            read_addr_spi <= addr + 1;
                        end
                        addr <= addr + 1;
                    end
                    bitcnt <= DATA_WIDTH - 1;
                end else begin
                    bitcnt <= bitcnt - 1;
                end
            end else begin
                // ── CS_N high: idle ─────────────────────────────
                shreg_rx      <= {DATA_WIDTH{1'b0}};
                bitcnt        <= DATA_WIDTH - 1;
                cmd_phase     <= 1'b0;
                rw_flag       <= 1'b0;
                addr          <= {ADDR_WIDTH{1'b0}};
                read_addr_spi <= {ADDR_WIDTH{1'b0}};
                rdata_sync0   <= {DATA_WIDTH{1'b0}};
                rdata_sync1   <= {DATA_WIDTH{1'b0}};
                wr_toggle_spi <= 1'b0;
                tx_load       <= 1'b0;
            end
        end
    end

    // ═════════════════════════════════════════════════════════════════
    // NEGEDGE: sole driver of shreg_tx and miso_q
    // ═════════════════════════════════════════════════════════════════
    reg  cs_n_d_n;   // CS_N edge detector (negedge domain)

    always @(negedge i_sclk or negedge i_rstn) begin
        if (!i_rstn) begin
            miso_q   <= 1'b0;
            shreg_tx <= {DATA_WIDTH{1'b0}};
            cs_n_d_n <= 1'b1;
        end else begin
            cs_n_d_n <= i_cs_n;

            if (!i_cs_n) begin
                if (!i_cs_n && cs_n_d_n) begin
                    // CS_N just fell: reset TX
                    miso_q   <= 1'b0;
                    shreg_tx <= {DATA_WIDTH{1'b0}};
                end else if (tx_load) begin
                    // Load new byte: MSB goes out this edge
                    miso_q   <= tx_next[DATA_WIDTH-1];
                    shreg_tx <= {tx_next[DATA_WIDTH-2:0], 1'b0};
                end else begin
                    // Normal shift
                    miso_q   <= shreg_tx[DATA_WIDTH-1];
                    shreg_tx <= {shreg_tx[DATA_WIDTH-2:0], 1'b0};
                end
            end else begin
                miso_q <= 1'b0;
            end
        end
    end

    // ── Write CDC: toggle synchroniser (SPI → sysclk) ──────────────
    reg  [1:0]  wr_sync;
    reg         wr_sync_d;

    always @(posedge i_sysclk or negedge i_rstn) begin
        if (!i_rstn) begin
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

endmodule
