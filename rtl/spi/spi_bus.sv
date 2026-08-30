//------------------------------------------------------------------------
// spi_bus.sv — the memory-map wire protocol (docs/memory_map.md)
//
// Wire format (SPI Mode 0, MSB first — one CS-framed transaction):
//
//   byte 0      command: [7] 1 = read, 0 = write
//                        [6] 1 = auto-increment address per word
//                        [5:0] reserved (ignored)
//   bytes 1..2  16-bit word address, MSB first
//   WRITE:  bytes 3..          32-bit data words, MSB first, streaming
//   READ:   bytes 3..4         two dummy bytes (turnaround)
//           bytes 5..          32-bit data words, MSB first, streaming
//
//   MISO: byte 0 = ID_BYTE (link check on every frame); address and
//   dummy slots = 0x00; read data slots = the addressed words.
//
// Why the read turnaround exists: the store's read port is in the
// sysclk domain (dual-clock semi dual-port BSRAM — true dual-port does
// not map on this toolchain, measured), so a fetch costs ~60 ns of
// synchronizer + BSRAM read. The first data byte's shift register loads
// HALF a bit period after the address completes — 12.5 ns at the
// measured 40 MHz SPI ceiling — so without turnaround the first word
// could never be fresh. Two dummy bytes give 400 ns. Burst words
// prefetch two byte-slots early for the same margin. (The very first
// firmware header specified "cmd + 2 dummy + N data"; it was right.)
//
// Wire format ≠ storage geometry: 16-bit addresses / 32-bit words on
// the wire; BACKED_WORDS × 36-bit BSRAM behind it (11-bit space today).
// Beyond the backed window: writes are dropped, reads return zero — no
// aliasing.
//
// Edge discipline as proven in spi_slave_regs.sv: MOSI sampled and
// decoded on the RISING edge, MISO loaded on the FALLING edge,
// posedge-CS async framing, power-up state declared.
//------------------------------------------------------------------------
`default_nettype none
module spi_bus #(
    parameter int   AW_BACKED = 11,          // 2048 words backed today
    parameter [7:0] ID_BYTE   = 8'hA5
) (
    // ---- SPI side (master's clock) ----
    input  logic        sclk,
    input  logic        cs,          // active low
    input  logic        mosi,
    output logic        miso,

    // ---- fabric side ----
    input  logic        sysclk,
    input  logic        rst_n,

    // ---- per-voice parameter writes (sclk domain) ------------------
    // The memory map's 0x2000 + v*64 range, offsets 0..3 (OSC, DUTY,
    // FILTER, GAIN). Combinational decode, valid exactly on the sclk
    // edge that completes a data word — the consumer writes its RAM on
    // that same edge (there may be no further edges: a master stops
    // clocking after the last bit). Offsets 4..63 are dropped for now;
    // per-voice read-back is TBD (reads in this range return zero).
    output logic        pv_we,
    output logic [1:0]  pv_bank,     // 0..3 = p0..p3
    output logic [7:0]  pv_voice,
    output logic [31:0] pv_wdata,

    // CTRL@0x0002 bit 0: bank swap request. Toggle semantics
    // (sclk domain); the consumer syncs the toggle and flips its
    // active bank at the next drum slot 512. The write also lands in
    // the plain window RAM, so reading CTRL back shows the last value.
    output logic        swap_req
);

    localparam int NWORDS = 1 << AW_BACKED;

    //--------------------------------------------------------------------
    // Receive — rising edge; a byte completes AT RE8
    //--------------------------------------------------------------------
    logic [7:0] rx_sh;
    logic [2:0] bit_cnt;

    wire [7:0] rx_byte  = {rx_sh[6:0], mosi};
    wire       byte_end = (bit_cnt == 3'd7);

    initial begin
        rx_sh   = '0;
        bit_cnt = '0;
    end

    always_ff @(posedge sclk or posedge cs) begin
        if (cs) begin
            rx_sh   <= '0;
            bit_cnt <= '0;
        end else begin
            rx_sh   <= rx_byte;
            bit_cnt <= bit_cnt + 3'd1;
        end
    end

    //--------------------------------------------------------------------
    // Frame decode (sclk domain)
    //   phase 0 cmd · 1 addr-hi · 2 addr-lo · 3 read turnaround · 4 data
    //--------------------------------------------------------------------
    logic [2:0]  phase;
    logic        is_read, auto_inc;
    logic [15:0] addr;
    logic        dummy2;        // second turnaround byte pending
    logic [1:0]  wbyte;         // byte index within the current word
    logic [23:0] wbuf;          // first three data bytes of a word

    wire in_window = (addr[15:AW_BACKED] == '0);

    // fetch request: toggle + quasi-static address (settle-time CDC,
    // same pattern as spi_slave_regs' hardware-proven STATUS capture)
    logic        req;
    logic [15:0] fetch_addr;
    logic [31:0] resp;         // fetched word (sysclk domain, see below)
    logic [31:0] tx_word;      // the word streaming out NOW — latched at
                               // each word boundary so prefetches into
                               // resp cannot clip the tail bytes

    initial begin
        phase      = '0;
        is_read    = 1'b0;
        auto_inc   = 1'b0;
        addr       = '0;
        dummy2     = 1'b0;
        wbyte      = '0;
        wbuf       = '0;
        req        = 1'b0;
        fetch_addr = '0;
        tx_word    = '0;
    end

    always_ff @(posedge sclk or posedge cs) begin
        if (cs) begin
            phase  <= '0;
            dummy2 <= 1'b0;
            wbyte  <= '0;
        end else if (byte_end) begin
            case (phase)
                3'd0: begin                       // command
                    is_read  <= rx_byte[7];
                    auto_inc <= rx_byte[6];
                    phase    <= 3'd1;
                end
                3'd1: begin                       // address high
                    addr[15:8] <= rx_byte;
                    phase      <= 3'd2;
                end
                3'd2: begin                       // address low
                    addr[7:0]  <= rx_byte;
                    fetch_addr <= {addr[15:8], rx_byte};
                    req        <= ~req;           // fetch word 0
                    wbyte      <= '0;
                    dummy2     <= 1'b0;
                    phase      <= is_read ? 3'd3 : 3'd4;
                end
                3'd3: begin                       // read turnaround (2 bytes)
                    dummy2 <= 1'b1;
                    if (dummy2) begin
                        phase   <= 3'd4;
                        tx_word <= resp;          // word 0, fetched >=2
                                                  // byte-slots ago
                    end
                end
                3'd4: begin                       // data words
                    wbuf  <= {wbuf[15:0], rx_byte};
                    wbyte <= wbyte + 2'd1;
                    // prefetch the NEXT word two byte-slots before it
                    // streams (>=500 ns at 40 MHz against ~60 ns needed)
                    if (wbyte == 2'd1) begin
                        fetch_addr <= auto_inc ? addr + 16'd1 : addr;
                        req        <= ~req;
                    end
                    if (wbyte == 2'd3) begin
                        tx_word <= resp;          // latch the prefetched
                                                  // next word; resp is
                                                  // free to change under
                                                  // later prefetches
                        if (auto_inc)
                            addr <= addr + 16'd1;
                    end
                end
                default: ;
            endcase
        end
    end

    //--------------------------------------------------------------------
    // Store — dual-clock semi dual-port BSRAM (write sclk, read sysclk).
    // Sync-only, reset-free processes so yosys infers DPX9B (AGENTS.md).
    //--------------------------------------------------------------------
    logic [35:0] mem [0:NWORDS-1];

    integer i0;
    initial for (i0 = 0; i0 < NWORDS; i0 = i0 + 1) mem[i0] = '0;

    wire mem_we = byte_end && (phase == 3'd4) && (wbyte == 2'd3)
                  && !is_read && in_window;

    // ---- per-voice write decode (0x2000..0x5FFF, offsets 0..3) -----
    wire        in_pv   = (addr >= 16'h2000) && (addr < 16'h6000);
    wire [15:0] pv_rel  = addr - 16'h2000;      // 0..0x3FFF within range
    wire [13:0] pv_off  = pv_rel[13:0];
    assign pv_we    = byte_end && (phase == 3'd4) && (wbyte == 2'd3)
                      && !is_read && in_pv && (pv_off[5:2] == 4'd0);
    assign pv_bank  = pv_off[1:0];
    assign pv_voice = pv_off[13:6];
    assign pv_wdata = {wbuf, rx_byte};

    always_ff @(posedge sclk) begin
        if (mem_we)
            mem[addr[AW_BACKED-1:0]] <= {4'b0, wbuf, rx_byte};
    end

    // CTRL decode: a write to 0x0002 with bit 0 set toggles swap_req.
    // Registered on the committing edge itself — no later edge is
    // guaranteed (framing rule).
    initial swap_req = 1'b0;
    always_ff @(posedge sclk) begin
        if (mem_we && (addr == 16'h0002) && rx_byte[0])
            swap_req <= ~swap_req;
    end

    //--------------------------------------------------------------------
    // Fetch service (sysclk domain)
    //--------------------------------------------------------------------
    logic req_m, req_s, req_d;
    logic        f_pending;
    logic [35:0] mem_q;

    initial begin
        {req_m, req_s, req_d} = '0;
        f_pending = 1'b0;
        mem_q     = '0;
        resp      = '0;
    end

    always_ff @(posedge sysclk) begin
        req_m <= req;
        req_s <= req_m;
        req_d <= req_s;

        mem_q     <= mem[fetch_addr[AW_BACKED-1:0]];   // BSRAM sync read
        f_pending <= (req_s != req_d);
        if (f_pending)
            resp <= (fetch_addr[15:AW_BACKED] == '0) ? mem_q[31:0] : 32'd0;
    end

    //--------------------------------------------------------------------
    // Transmit — falling edge.  phase/wbyte have already advanced at the
    // RE8 before this FE8 load, so they index the slot about to stream.
    //--------------------------------------------------------------------
    wire [7:0] tx_byte =
        (phase == 3'd0) ? ID_BYTE :
        (phase != 3'd4) ? 8'h00   :
        !is_read        ? 8'h00   :
        (wbyte == 2'd0) ? tx_word[31:24] :
        (wbyte == 2'd1) ? tx_word[23:16] :
        (wbyte == 2'd2) ? tx_word[15:8]  :
                          tx_word[7:0];

    logic [7:0] tx_sh;
    initial tx_sh = ID_BYTE;

    always_ff @(negedge sclk or posedge cs) begin
        if (cs)
            tx_sh <= ID_BYTE;
        else if (bit_cnt == 3'd0)
            tx_sh <= tx_byte;
        else
            tx_sh <= {tx_sh[6:0], 1'b0};
    end

    assign miso = cs ? 1'b0 : tx_sh[7];

endmodule
`default_nettype wire
