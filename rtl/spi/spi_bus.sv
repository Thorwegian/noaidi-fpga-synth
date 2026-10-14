//------------------------------------------------------------------------
// spi_bus.sv — the memory-map wire protocol (docs/memory_map.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
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
// What the words address (docs/memory_map.md):
//
//   0x0000–0x000F  system registers (read back): CTRL, scratch; 0x0008–0x000B and
//                  0x000D–0x000E are read-only diagnostics, 0x000C picks the CSP
//                  register pair the probe reads (0x000D, 0x000E)
//   0x0010         PROGRAM_HIGH: bits 35:32 of the next instruction write
//   0x2000 + 64 p  partial p's pointers, words 0..3 (the fourth commits)
//   0x6000 + a     the CSP's write queue: register or sink word a
//   0x8000 + pc    the CSP's instruction memory (while the CSP is held)
//
// Why the read turnaround exists: a read is served in the sysclk domain,
// so a fetch costs ~60 ns of synchronizer. The first data byte's shift
// register loads HALF a bit period after the address completes — 12.5 ns
// at the measured 40 MHz SPI ceiling — so without turnaround the first
// word could never be fresh. Two dummy bytes give 400 ns. Burst words
// prefetch two byte-slots early for the same margin.
//
// Writes outside the ranges above are dropped, reads return zero — no
// aliasing.
//
// Every write strobe is a combinational decode, valid exactly on the sclk
// edge that completes a data word — the consumer takes it on that same
// edge (there may be no further edges: a master stops clocking after the
// last bit). Edge discipline as proven in spi_slave_regs.sv: MOSI sampled
// and decoded on the RISING edge, MISO loaded on the FALLING edge,
// posedge-CS async framing, power-up state declared.
//------------------------------------------------------------------------
`default_nettype none
module spi_bus #(
    parameter [7:0] ID_BYTE   = synth_pkg::SPI_ID_BYTE
) (
    // ---- SPI side (master's clock) ----
    input  logic        sclk,
    input  logic        cs,          // active low
    input  logic        mosi,
    output logic        miso,

    // ---- partial pointers (sclk domain) -----------------------------------
    // Partial p's ten pointers, written whole when its fourth word arrives.
    output logic        pointer_write_enable,
    output logic [7:0]  pointer_write_index,
    output logic [synth_pkg::POINTER_ENTRY_W-1:0] pointer_write_data,

    // ---- the CSP (sclk domain) ---------------------------------------------
    // A register or sink write waits in the write queue until `swap`
    // commits it; the program loads while the CSP is held.
    output logic        queue_write_enable,
    output logic [csp_pkg::QUEUE_ADDRESS_W-1:0] queue_write_address,
    output logic [csp_pkg::WORD_W-1:0]          queue_write_data,
    output logic        swap,                 // one sclk cycle: commit the queue
    output logic        imem_write_enable,
    output logic [csp_pkg::PROGRAM_W-1:0]       imem_write_address,
    output logic [35:0] imem_write_data,
    output logic        csp_held,             // CTRL[1]: the CSP is held in reset
    output logic        test_tone_enable,     // CTRL[2]

    // ---- diagnostics (sclk domain, read-only words 0x0008-0x000B) ----------
    input  logic [31:0] status_0,
    input  logic [31:0] status_1,
    input  logic [31:0] status_2,
    input  logic [31:0] status_3,
    input  logic [31:0] status_4,
    input  logic [31:0] status_5,
    output logic [10:0] probe_address        // system register 0x000C: which CSP register pair to probe
);

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
    // The system registers: read back from the sclk domain, so a read needs
    // no clock crossing. CTRL (0x0002) keeps what was written, less the
    // swap request, which is an event and not a state.
    //--------------------------------------------------------------------
    localparam int SYSTEM_WORDS = 16;
    logic [31:0] system_register [SYSTEM_WORDS];
    initial for (int word = 0; word < SYSTEM_WORDS; word++) system_register[word] = '0;

    function automatic logic [31:0] read_word(input logic [15:0] address);
        case (address)
            16'h0008: read_word = status_0;
            16'h0009: read_word = status_1;
            16'h000A: read_word = status_2;
            16'h000B: read_word = status_3;
            16'h000D: read_word = status_4;
            16'h000E: read_word = status_5;
            default:  read_word = address < 16'(SYSTEM_WORDS) ? system_register[address[3:0]] : 32'd0;
        endcase
    endfunction

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
    logic [31:0] stream_word;       // the word streaming out NOW

    initial begin
        frame_phase      = '0;
        is_read          = 1'b0;
        auto_increment   = 1'b0;
        word_addr        = '0;
        first_dummy_done = 1'b0;
        data_byte_index  = '0;
        partial_word     = '0;
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
                    stream_word     <= read_word({word_addr[15:8], rx_byte});
                    data_byte_index <= '0;
                    first_dummy_done <= 1'b0;
                    frame_phase     <= is_read ? 3'd3 : 3'd4;
                end
                3'd3: begin                       // read turnaround (2 bytes)
                    first_dummy_done <= 1'b1;
                    if (first_dummy_done) begin
                        frame_phase <= 3'd4;
                    end
                end
                3'd4: begin                       // data words
                    partial_word    <= {partial_word[15:0], rx_byte};
                    data_byte_index <= data_byte_index + 2'd1;
                    if (data_byte_index == 2'd3) begin
                        // the next word of a burst
                        stream_word <= read_word(auto_increment ? word_addr + 16'd1 : word_addr);
                        if (auto_increment)
                            word_addr <= word_addr + 16'd1;
                    end
                end
                default: ;
            endcase
        end
    end

    //--------------------------------------------------------------------
    // Write decode. A word completes at the edge that receives its last
    // byte; every strobe below is valid on that edge, and its data are the
    // word on the wire: {partial_word, rx_byte}.
    //--------------------------------------------------------------------
    wire        word_complete = byte_end && (frame_phase == 3'd4)
                                && (data_byte_index == 2'd3) && !is_read;
    wire [31:0] word_data     = {partial_word, rx_byte};

    // ---- the system registers (0x0000–0x000F) and PROGRAM_HIGH (0x0010) ----
    localparam [15:0] CTRL_ADDRESS = synth_pkg::MAP_CTRL_ADDR;
    localparam [15:0] PROGRAM_HIGH_ADDRESS = synth_pkg::MAP_PROGRAM_HIGH_ADDR;
    wire in_system = word_complete && word_addr < 16'(SYSTEM_WORDS);

    // CTRL: [0] swap request (an event), [1] hold the CSP, [2] test tone
    assign swap = in_system && word_addr == CTRL_ADDRESS && word_data[0];

    always_ff @(posedge sclk) begin
        if (in_system) begin
            system_register[word_addr[3:0]] <= word_addr == CTRL_ADDRESS
                                               ? word_data & ~32'd1 : word_data;
        end
    end
    assign probe_address = system_register[12][10:0];
    // The held and test-tone levels follow CTRL as written, from the edge
    // after the word completes.
    initial begin
        csp_held         = 1'b1;     // the CSP starts held: nothing runs until a program is loaded
        test_tone_enable = 1'b0;
    end
    always_ff @(posedge sclk) begin
        if (in_system && word_addr == CTRL_ADDRESS) begin
            csp_held         <= word_data[1];
            test_tone_enable <= word_data[2];
        end
    end

    logic [3:0] program_high;
    initial program_high = '0;
    always_ff @(posedge sclk) begin
        if (word_complete && word_addr == PROGRAM_HIGH_ADDRESS) begin
            program_high <= word_data[3:0];
        end
    end

    // The ranges must not overlap: a write would be taken for two things.
    localparam [15:0] QUEUE_END   = synth_pkg::MAP_QUEUE_BASE + 16'(1 << csp_pkg::QUEUE_ADDRESS_W);
    localparam [15:0] PROGRAM_END = synth_pkg::MAP_PROGRAM_BASE + 16'(csp_pkg::MAX_PROGRAM);
    if (synth_pkg::MAP_PARTIAL_BASE + 16'(synth_pkg::NUM_PARTIALS * synth_pkg::MAP_PARTIAL_STRIDE)
            > synth_pkg::MAP_QUEUE_BASE
        || QUEUE_END > synth_pkg::MAP_PROGRAM_BASE
        || PROGRAM_END < synth_pkg::MAP_PROGRAM_BASE) begin : g_ranges_overlap
        $error("spi_bus: the pointer, queue and program ranges overlap");
    end

    // ---- the CSP's instruction memory (0x8000 + pc) ----------------------
    wire in_instruction_range = word_addr >= synth_pkg::MAP_PROGRAM_BASE
                                && word_addr < synth_pkg::MAP_PROGRAM_BASE + 16'(csp_pkg::MAX_PROGRAM);
    assign imem_write_enable  = word_complete && in_instruction_range;
    assign imem_write_address = csp_pkg::PROGRAM_W'(word_addr - synth_pkg::MAP_PROGRAM_BASE);
    assign imem_write_data    = {program_high, word_data};

    // ---- the CSP's write queue (0x6000 + register or sink address) -------
    wire in_queue_range = word_addr >= synth_pkg::MAP_QUEUE_BASE
                          && word_addr < synth_pkg::MAP_QUEUE_BASE + 16'(1 << csp_pkg::QUEUE_ADDRESS_W);
    assign queue_write_enable  = word_complete && in_queue_range;
    assign queue_write_address = csp_pkg::QUEUE_ADDRESS_W'(word_addr - synth_pkg::MAP_QUEUE_BASE);
    assign queue_write_data    = word_data[csp_pkg::WORD_W-1:0];

    // ---- partial pointers (0x2000 + 64 p, words 0..3) --------------------
    // A partial's ten pointers are 10 bits each, three to a word; the fourth
    // word commits the entry, whole.
    localparam [15:0] PARTIAL_BASE = synth_pkg::MAP_PARTIAL_BASE;
    localparam [15:0] PARTIAL_END  = synth_pkg::MAP_PARTIAL_BASE
                                + 16'(synth_pkg::NUM_PARTIALS
                                      * synth_pkg::MAP_PARTIAL_STRIDE);
    wire        in_partial_range = word_addr >= PARTIAL_BASE && word_addr < PARTIAL_END;
    wire [13:0] partial_offset   = (word_addr - PARTIAL_BASE) & 16'h3FFF;
    wire [5:0]  pointer_word     = partial_offset[5:0];

    logic [29:0] pointer_stage [3];
    initial for (int word = 0; word < 3; word++) pointer_stage[word] = '0;
    always_ff @(posedge sclk) begin
        if (word_complete && in_partial_range && pointer_word < 6'd3) begin
            pointer_stage[pointer_word[1:0]] <= word_data[29:0];
        end
    end
    assign pointer_write_enable = word_complete && in_partial_range && pointer_word == 6'd3;
    assign pointer_write_index  = partial_offset[13:6];
    assign pointer_write_data   = {word_data[synth_pkg::POINTER_W-1:0], pointer_stage[2],
                                   pointer_stage[1], pointer_stage[0]};

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
