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
    parameter int   AW_BACKED = synth_pkg::MAP_AW_BACKED,  // 2048 words backed
    parameter [7:0] ID_BYTE   = synth_pkg::SPI_ID_BYTE
) (
    // ---- SPI side (master's clock) ----
    input  logic        sclk,
    input  logic        cs,          // active low
    input  logic        mosi,
    output logic        miso,

    // ---- fabric side ----
    input  logic        sysclk,
    input  logic        rst_n,

    // ---- per-element parameter writes (sclk domain) ----------------
    // The memory map's 0x2000 + v*64 range, offsets 0..6 (OSC, DUTY,
    // FILTER, GAIN, GATE, PTRS0, PTRS1). Combinational decode, valid
    // exactly on the sclk edge that completes a data word — the
    // consumer writes its RAM on that same edge (there may be no
    // further edges: a master stops clocking after the last bit).
    // Offsets 7..63 are dropped for now; per-element read-back is TBD
    // (reads in this range return zero).
    output logic        elem_write_enable,
    output logic [2:0]  elem_write_word,   // 0..6 = OSC..PTRS1 param RAM

    // ---- bus base writes (sclk domain, mailbox toward sysclk) ------
    // Bus values are live (no ping-pong). The write crosses clock
    // domains through this 1-deep toggle mailbox; the pipeline syncs
    // bus_write_toggle and commits to bus RAM only in an idle drum
    // slot, so a commit can never collide with a lane's bus read (the
    // BSRAM read-during-write corruption class stays impossible by
    // construction, not by probability). Overrun math: one SPI word
    // takes >= ~5.6 us at 10 MHz; a commit waits at most one lane
    // span (~3.7 us) — back-to-back writes cannot outrun the mailbox.
    output logic [9:0]  bus_write_addr,
    output logic [17:0] bus_write_data,
    output logic        bus_write_toggle,  // toggles once per bus write

    // ---- producer table writes (sclk domain, banked like params) ---
    // Producer config is wiring: it rides the ping-pong banks and
    // takes effect at the swap, same as the per-element words.
    output logic        producer_write_enable,
    output logic [8:0]  producer_write_addr,   // {entry[6:0], word[1:0]}
    output logic [31:0] producer_write_data,
    output logic [7:0]  elem_write_index,
    output logic [31:0] elem_write_data,

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
    logic [7:0] rx_shift;
    logic [2:0] bit_count;

    wire [7:0] rx_byte  = {rx_shift[6:0], mosi};
    wire       byte_end = (bit_count == 3'd7);

    initial begin
        rx_shift  = '0;
        bit_count = '0;
    end

    always_ff @(posedge sclk or posedge cs) begin
        if (cs) begin
            rx_shift  <= '0;
            bit_count <= '0;
        end else begin
            rx_shift  <= rx_byte;
            bit_count <= bit_count + 3'd1;
        end
    end

    //--------------------------------------------------------------------
    // Frame decode (sclk domain)
    //   phase 0 cmd · 1 addr-hi · 2 addr-lo · 3 read turnaround · 4 data
    //--------------------------------------------------------------------
    logic [2:0]  frame_phase;
    logic        is_read, auto_increment;
    logic [15:0] word_addr;
    logic        first_dummy_done;  // second turnaround byte pending
    logic [1:0]  data_byte_index;   // byte index within the current word
    logic [23:0] partial_word;      // first three data bytes of a word

    wire addr_in_backed = (word_addr[15:AW_BACKED] == '0);

    // fetch request: toggle + quasi-static address (settle-time CDC,
    // same pattern as spi_slave_regs' hardware-proven STATUS capture)
    logic        fetch_toggle;
    logic [15:0] fetch_addr;
    logic [31:0] fetch_result;  // fetched word (sysclk domain, see below)
    logic [31:0] stream_word;   // the word streaming out NOW — latched at
                                // each word boundary so prefetches into
                                // fetch_result cannot clip the tail bytes

    initial begin
        frame_phase      = '0;
        is_read          = 1'b0;
        auto_increment   = 1'b0;
        word_addr        = '0;
        first_dummy_done = 1'b0;
        data_byte_index  = '0;
        partial_word     = '0;
        fetch_toggle     = 1'b0;
        fetch_addr       = '0;
        stream_word      = '0;
    end

    always_ff @(posedge sclk or posedge cs) begin
        if (cs) begin
            frame_phase      <= '0;
            first_dummy_done <= 1'b0;
            data_byte_index  <= '0;
        end else if (byte_end) begin
            case (frame_phase)
                3'd0: begin                       // command
                    is_read        <= rx_byte[7];
                    auto_increment <= rx_byte[6];
                    frame_phase    <= 3'd1;
                end
                3'd1: begin                       // address high
                    word_addr[15:8] <= rx_byte;
                    frame_phase     <= 3'd2;
                end
                3'd2: begin                       // address low
                    word_addr[7:0]  <= rx_byte;
                    fetch_addr      <= {word_addr[15:8], rx_byte};
                    fetch_toggle    <= ~fetch_toggle;   // fetch word 0
                    data_byte_index <= '0;
                    first_dummy_done <= 1'b0;
                    frame_phase     <= is_read ? 3'd3 : 3'd4;
                end
                3'd3: begin                       // read turnaround (2 bytes)
                    first_dummy_done <= 1'b1;
                    if (first_dummy_done) begin
                        frame_phase <= 3'd4;
                        stream_word <= fetch_result;  // word 0, fetched
                                                      // >=2 byte-slots ago
                    end
                end
                3'd4: begin                       // data words
                    partial_word    <= {partial_word[15:0], rx_byte};
                    data_byte_index <= data_byte_index + 2'd1;
                    // prefetch the NEXT word two byte-slots before it
                    // streams (>=500 ns at 40 MHz against ~60 ns needed)
                    if (data_byte_index == 2'd1) begin
                        fetch_addr   <= auto_increment ? word_addr + 16'd1
                                                       : word_addr;
                        fetch_toggle <= ~fetch_toggle;
                    end
                    if (data_byte_index == 2'd3) begin
                        stream_word <= fetch_result;  // latch the
                                                      // prefetched next
                                                      // word; fetch_result
                                                      // is free to change
                                                      // under later
                                                      // prefetches
                        if (auto_increment)
                            word_addr <= word_addr + 16'd1;
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
    logic [35:0] store_ram [0:NWORDS-1];

    integer i0;
    initial for (i0 = 0; i0 < NWORDS; i0 = i0 + 1) store_ram[i0] = '0;

    wire store_write_enable = byte_end && (frame_phase == 3'd4)
                              && (data_byte_index == 2'd3)
                              && !is_read && addr_in_backed;

    // ---- per-element write decode (MAP_ELEM_BASE + 256×64 words,
    //      offsets 0..6) -------------------------------------------
    localparam [15:0] ELEM_BASE = synth_pkg::MAP_ELEM_BASE;
    localparam [15:0] ELEM_END  = synth_pkg::MAP_ELEM_BASE
                                + 16'(synth_pkg::NUM_ELEMENTS
                                      * synth_pkg::MAP_ELEM_STRIDE);
    wire        in_elem_range = (word_addr >= ELEM_BASE)
                             && (word_addr <  ELEM_END);
    wire [15:0] elem_rel_addr = word_addr - ELEM_BASE; // 0..0x3FFF in range
    wire [13:0] elem_offset   = elem_rel_addr[13:0];
    assign elem_write_enable = byte_end && (frame_phase == 3'd4)
                               && (data_byte_index == 2'd3)
                               && !is_read && in_elem_range
                               && (elem_offset[5:3] == 3'd0)
                               && (elem_offset[2:0] < 3'd7);
    assign elem_write_word   = elem_offset[2:0];

    // ---- producer table write decode (0x0100..0x02FF) --------------
    localparam [15:0] PROD_BASE = synth_pkg::MAP_PROD_BASE;
    localparam [15:0] PROD_END  = synth_pkg::MAP_PROD_BASE
                                + 16'(4 * synth_pkg::NUM_PRODUCERS);
    wire in_producer_range = (word_addr >= PROD_BASE)
                          && (word_addr <  PROD_END)
                          && (word_addr[1:0] != 2'd3);  // word 3 reserved
    assign producer_write_enable = byte_end && (frame_phase == 3'd4)
                                   && (data_byte_index == 2'd3)
                                   && !is_read && in_producer_range;
    // Region-relative offset — word_addr[8:0] alone is WRONG here: the
    // region starts at 0x0100, whose bit 8 is set, so a raw slice
    // lands writes 64 entries off.
    assign producer_write_addr = 9'(word_addr - synth_pkg::MAP_PROD_BASE);
    assign producer_write_data = {partial_word, rx_byte};

    // ---- bus base write capture (see mailbox note at the ports) ----
    wire in_bus_range = (word_addr >= synth_pkg::MAP_BUS_BASE)
                     && (word_addr <  synth_pkg::MAP_BUS_BASE
                                      + 16'(synth_pkg::NUM_BUSES));
    initial bus_write_toggle = 1'b0;
    always_ff @(posedge sclk) begin
        if (byte_end && (frame_phase == 3'd4) && (data_byte_index == 2'd3)
            && !is_read && in_bus_range) begin
            bus_write_addr   <= word_addr[9:0];
            bus_write_data   <= {partial_word[9:0], rx_byte}; // low 18 bits
            bus_write_toggle <= ~bus_write_toggle;
        end
    end
    assign elem_write_index = elem_offset[13:6];
    assign elem_write_data  = {partial_word, rx_byte};

    always_ff @(posedge sclk) begin
        if (store_write_enable)
            store_ram[word_addr[AW_BACKED-1:0]] <= {4'b0, partial_word, rx_byte};
    end

    // CTRL decode: a write to 0x0002 with bit 0 set toggles swap_req.
    // Registered on the committing edge itself — no later edge is
    // guaranteed (framing rule).
    initial swap_req = 1'b0;
    always_ff @(posedge sclk) begin
        if (store_write_enable && (word_addr == synth_pkg::MAP_CTRL_ADDR)
            && rx_byte[0])
            swap_req <= ~swap_req;
    end

    //--------------------------------------------------------------------
    // Fetch service (sysclk domain)
    //--------------------------------------------------------------------
    logic fetch_toggle_meta, fetch_toggle_sync, fetch_toggle_prev;
    logic        fetch_pending;
    logic [35:0] store_read_data;

    initial begin
        {fetch_toggle_meta, fetch_toggle_sync, fetch_toggle_prev} = '0;
        fetch_pending   = 1'b0;
        store_read_data = '0;
        fetch_result    = '0;
    end

    always_ff @(posedge sysclk) begin
        fetch_toggle_meta <= fetch_toggle;
        fetch_toggle_sync <= fetch_toggle_meta;
        fetch_toggle_prev <= fetch_toggle_sync;

        store_read_data <= store_ram[fetch_addr[AW_BACKED-1:0]]; // BSRAM sync read
        fetch_pending   <= (fetch_toggle_sync != fetch_toggle_prev);
        if (fetch_pending)
            fetch_result <= (fetch_addr[15:AW_BACKED] == '0)
                          ? store_read_data[31:0] : 32'd0;
    end

    //--------------------------------------------------------------------
    // Transmit — falling edge.  frame_phase/data_byte_index have already
    // advanced at the RE8 before this FE8 load, so they index the slot
    // about to stream.
    //--------------------------------------------------------------------
    wire [7:0] tx_byte =
        (frame_phase == 3'd0)      ? ID_BYTE :
        (frame_phase != 3'd4)      ? 8'h00   :
        !is_read                   ? 8'h00   :
        (data_byte_index == 2'd0)  ? stream_word[31:24] :
        (data_byte_index == 2'd1)  ? stream_word[23:16] :
        (data_byte_index == 2'd2)  ? stream_word[15:8]  :
                                     stream_word[7:0];

    logic [7:0] tx_shift;
    initial tx_shift = ID_BYTE;

    always_ff @(negedge sclk or posedge cs) begin
        if (cs)
            tx_shift <= ID_BYTE;
        else if (bit_count == 3'd0)
            tx_shift <= tx_byte;
        else
            tx_shift <= {tx_shift[6:0], 1'b0};
    end

    assign miso = cs ? 1'b0 : tx_shift[7];

endmodule
`default_nettype wire
