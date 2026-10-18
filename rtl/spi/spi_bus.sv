//------------------------------------------------------------------------
// spi_bus.sv — the memory-map wire protocol, in nines (docs/memory_map.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Wire format (SPI Mode 0, MSB first, one CS-framed transaction). Every
// block RAM on the chip is 9, 18 or 36 bits wide, so the wire is too:
//
//   nonad 0        the command, 9 bits: [8] 1 = read, 0 = write
//                                       [7] 1 = auto-increment the address per quad
//                                       [6:0] reserved (ignored)
//   nonads 1..2    the address, 18 bits, in quads, MSB first
//   WRITE:  nonads 3..     36-bit quads, four nonads each, streaming
//   READ:   nonads 3..6    one turnaround quad (the fetch's time)
//           nonads 7..     36-bit quads, four nonads each, streaming
//
//   MISO: nonad 0 = the ID nonad (a link check on every frame); the
//   address and turnaround slots = 0; the read slots = the quads read.
//
// What the quads address (docs/memory_map.md): the sixteen system quads
// at 0x00000–0x0000F — CTRL, scratch, the probe address, the status
// quads — the write FIFO's door at 0x06000, IMEM's rows at 0x08000 (two
// quads a row) and the decode ROM's at 0x09000 (one quad a row). Writes
// outside the ranges are dropped, reads return zero: no aliasing.
//
// Reads run one quad ahead: `quad_address` names the quad after the one
// streaming, from the turnaround on, and `read_data` is sampled at the
// end of the turnaround and of every quad — a block RAM behind it has
// the four nonads of a quad, thirty-six clocks, to answer, and the
// system quads answer at once. That is why the read turnaround exists:
// the first quad's shift register loads half a bit period after the
// address completes, 12.5 ns at the measured 40 MHz ceiling, and a
// block's answer needs a clock of its own.
//
// Every write strobe is a combinational decode, valid exactly on the sclk
// edge that completes a quad — the consumer takes it on that same edge
// (there may be no further edges: a master stops clocking after the last
// bit). MOSI is sampled and decoded on the RISING edge, MISO loaded on
// the FALLING edge, with posedge-CS asynchronous framing and the power-up
// state declared.
//------------------------------------------------------------------------
`default_nettype none
module spi_bus #(
    parameter logic [synth_pkg::SPI_NONAD_W-1:0] ID_NONAD = synth_pkg::SPI_ID_NONAD
) (
    // ---- SPI side (the master's clock) ----
    input  logic        sclk,
    input  logic        cs,          // active low
    input  logic        mosi,
    output logic        miso,

    // ---- CTRL's levels and event (sclk domain) ---------------------------
    output logic        swap,                 // one sclk cycle: commit the write FIFO
    output logic        csp_held,             // CTRL[1]: the CSP is held in reset
    output logic        test_tone_enable,     // CTRL[2]
    output logic        data_stream_enable,   // CTRL[3]: the 48 kHz S/PDIF carries the data stream
    output logic [1:0]  stream_source,        // CTRL[5:4]
    output logic [csp_pkg::REGISTER_W-1:0] probe_address,   // system quad 0xC

    // ---- the status quads (sclk domain, read-only, 0x8–0xF) --------------
    input  logic [synth_pkg::MAP_SYSTEM_QUADS-synth_pkg::MAP_STORED_QUADS-1:0][synth_pkg::SPI_QUAD_W-1:0] status,

    // ---- the write FIFO's door ---------------------------------------------
    output logic                             fifo_write_enable,
    output logic [synth_pkg::SPI_QUAD_W-1:0] fifo_write_quad,

    // ---- IMEM and the decode ROM: the load, and the read-back ----------------
    output logic                             imem_load_enable,
    output logic [csp_pkg::PROGRAM_W-1:0]    imem_row,          // the load's row, or the read-back's
    output logic                             imem_upper,
    output logic [synth_pkg::SPI_QUAD_W-1:0] imem_load_quad,
    input  logic [synth_pkg::SPI_QUAD_W-1:0] imem_read_quad,    // the clock after imem_row
    output logic                             rom_load_enable,
    output logic [csp_pkg::ROM_ADDRESS_W-1:0] rom_row,
    output logic [csp_pkg::ROM_W-1:0]        rom_load_word,
    input  logic [csp_pkg::ROM_W-1:0]        rom_read_word
);

    //--------------------------------------------------------------------
    // Receive — rising edge; a nonad completes at its ninth bit.
    //--------------------------------------------------------------------
    logic [synth_pkg::SPI_NONAD_W-2:0] rx_shift;
    logic [3:0]             bit_count;

    wire [synth_pkg::SPI_NONAD_W-1:0] rx_nonad  = {rx_shift, mosi};
    wire                   nonad_end = bit_count == 4'(synth_pkg::SPI_NONAD_W - 1);

    initial begin
        rx_shift  = '0;
        bit_count = '0;
    end

    always_ff @(posedge sclk or posedge cs) begin
        if (cs) begin
            rx_shift  <= '0;
            bit_count <= '0;
        end else begin
            rx_shift  <= rx_nonad[synth_pkg::SPI_NONAD_W-2:0];
            bit_count <= nonad_end ? '0 : bit_count + 4'd1;
        end
    end

    //--------------------------------------------------------------------
    // The map's regions.
    //--------------------------------------------------------------------
    localparam logic [synth_pkg::SPI_ADDRESS_W-1:0] IMEM_END = synth_pkg::MAP_IMEM_BASE + synth_pkg::SPI_ADDRESS_W'(2 * csp_pkg::PROGRAM_ROWS);
    localparam logic [synth_pkg::SPI_ADDRESS_W-1:0] ROM_END  = synth_pkg::MAP_ROM_BASE + synth_pkg::SPI_ADDRESS_W'(csp_pkg::ROM_ROWS);

    function automatic logic in_system(input logic [synth_pkg::SPI_ADDRESS_W-1:0] address);
        in_system = address < synth_pkg::SPI_ADDRESS_W'(synth_pkg::MAP_SYSTEM_QUADS);
    endfunction
    function automatic logic in_imem(input logic [synth_pkg::SPI_ADDRESS_W-1:0] address);
        in_imem = address >= synth_pkg::MAP_IMEM_BASE && address < IMEM_END;
    endfunction
    function automatic logic in_rom(input logic [synth_pkg::SPI_ADDRESS_W-1:0] address);
        in_rom = address >= synth_pkg::MAP_ROM_BASE && address < ROM_END;
    endfunction

    //--------------------------------------------------------------------
    // The system quads: read back from the sclk domain, so a read needs
    // no clock crossing. CTRL (0x2) keeps what was written, less the swap
    // request, which is an event and not a state.
    //--------------------------------------------------------------------
    logic [synth_pkg::SPI_QUAD_W-1:0] system_quad [synth_pkg::MAP_STORED_QUADS];
    logic [csp_pkg::REGISTER_W-1:0] probe_register;
    initial begin
        for (int quad = 0; quad < synth_pkg::MAP_STORED_QUADS; quad++) system_quad[quad] = '0;
        probe_register = csp_pkg::REGISTER_W'(csp_pkg::PARK_REGISTER);   // a pair nothing writes
    end

    function automatic logic [synth_pkg::SPI_QUAD_W-1:0] system_at(input logic [synth_pkg::SPI_ADDRESS_W-1:0] address);
        if (address < synth_pkg::SPI_ADDRESS_W'(synth_pkg::MAP_STORED_QUADS)) begin
            system_at = system_quad[address[2:0]];
        end else if (address == synth_pkg::MAP_PROBE_ADDRESS) begin
            system_at = synth_pkg::SPI_QUAD_W'(probe_register);
        end else begin
            system_at = status[address[2:0]];
        end
    endfunction

    //--------------------------------------------------------------------
    // Frame decode (sclk domain)
    //   phase 0 command · 1 address high · 2 address low · 3 turnaround · 4 data
    //--------------------------------------------------------------------
    typedef enum logic [2:0] {
        PHASE_COMMAND      = 3'd0,
        PHASE_ADDRESS_HIGH = 3'd1,
        PHASE_ADDRESS_LOW  = 3'd2,
        PHASE_TURNAROUND   = 3'd3,
        PHASE_DATA         = 3'd4
    } phase_e;

    phase_e                   frame_phase;
    logic                     is_read, auto_increment;
    logic [synth_pkg::SPI_ADDRESS_W-1:0] quad_address;     // the quad being written, or the one after the one streaming
    logic [1:0]               nonad_index;      // the nonad within the current quad
    logic [synth_pkg::SPI_QUAD_W-synth_pkg::SPI_NONAD_W-1:0] partial_quad;   // the quad's first three nonads
    logic [synth_pkg::SPI_QUAD_W-1:0]    stream_quad;      // the quad streaming out NOW

    initial begin
        frame_phase    = PHASE_COMMAND;
        is_read        = 1'b0;
        auto_increment = 1'b0;
        quad_address   = '0;
        nonad_index    = '0;
        partial_quad   = '0;
        stream_quad    = '0;
    end

    wire last_nonad_of_quad = nonad_index == 2'(synth_pkg::SPI_NONADS_PER_QUAD - 1);
    wire [synth_pkg::SPI_ADDRESS_W-1:0] address_on_wire = {quad_address[synth_pkg::SPI_ADDRESS_W-1:synth_pkg::SPI_NONAD_W], rx_nonad};

    // What the address names, answered at once (the system quads) or the
    // clock after it was put on a block's pins (IMEM, the ROM).
    logic [synth_pkg::SPI_QUAD_W-1:0] read_data;
    always_comb begin
        if (in_system(quad_address))    read_data = system_at(quad_address);
        else if (in_imem(quad_address)) read_data = imem_read_quad;
        else if (in_rom(quad_address))  read_data = synth_pkg::SPI_QUAD_W'(rom_read_word);
        else                            read_data = '0;
    end

    always_ff @(posedge sclk or posedge cs) begin
        if (cs) begin
            frame_phase <= PHASE_COMMAND;
            nonad_index <= '0;
        end else if (nonad_end) begin
            case (frame_phase)
                PHASE_COMMAND: begin
                    is_read        <= rx_nonad[synth_pkg::SPI_NONAD_W-1];
                    auto_increment <= rx_nonad[synth_pkg::SPI_NONAD_W-2];
                    frame_phase    <= PHASE_ADDRESS_HIGH;
                end
                PHASE_ADDRESS_HIGH: begin
                    quad_address[synth_pkg::SPI_ADDRESS_W-1:synth_pkg::SPI_NONAD_W] <= rx_nonad;
                    frame_phase <= PHASE_ADDRESS_LOW;
                end
                PHASE_ADDRESS_LOW: begin
                    quad_address <= address_on_wire;
                    nonad_index  <= '0;
                    frame_phase  <= is_read ? PHASE_TURNAROUND : PHASE_DATA;
                end
                PHASE_TURNAROUND: begin                  // one quad's worth of nonads
                    nonad_index <= nonad_index + 2'd1;
                    if (last_nonad_of_quad) begin
                        stream_quad  <= read_data;       // the first quad, ready since the address
                        quad_address <= quad_address + synth_pkg::SPI_ADDRESS_W'(auto_increment);
                        frame_phase  <= PHASE_DATA;
                    end
                end
                PHASE_DATA: begin
                    partial_quad <= {partial_quad[synth_pkg::SPI_QUAD_W-2*synth_pkg::SPI_NONAD_W-1:0], rx_nonad};
                    nonad_index  <= nonad_index + 2'd1;
                    if (last_nonad_of_quad) begin
                        if (is_read) begin
                            stream_quad <= read_data;    // the next quad of a burst
                        end
                        quad_address <= quad_address + synth_pkg::SPI_ADDRESS_W'(auto_increment);
                    end
                end
                default: ;
            endcase
        end
    end

    //--------------------------------------------------------------------
    // Write decode. A quad completes at the edge that receives its last
    // nonad; every strobe below is valid on that edge, and its data are
    // the quad on the wire: {partial_quad, rx_nonad}.
    //--------------------------------------------------------------------
    wire                   quad_complete = nonad_end && frame_phase == PHASE_DATA
                                           && last_nonad_of_quad && !is_read;
    wire [synth_pkg::SPI_QUAD_W-1:0]  quad_data     = {partial_quad, rx_nonad};

    wire to_system = quad_complete && in_system(quad_address);
    wire to_ctrl   = to_system && quad_address == synth_pkg::MAP_CTRL;

    // CTRL: the swap is an event; the rest are levels.
    assign swap = to_ctrl && quad_data[synth_pkg::CTRL_SWAP];

    always_ff @(posedge sclk) begin
        if (to_system && quad_address[3] == 1'b0) begin
            system_quad[quad_address[2:0]] <= to_ctrl ? quad_data & ~(synth_pkg::SPI_QUAD_W'(1) << synth_pkg::CTRL_SWAP) : quad_data;
        end
        if (to_system && quad_address == synth_pkg::MAP_PROBE_ADDRESS) begin
            probe_register <= quad_data[csp_pkg::REGISTER_W-1:0];
        end
    end
    assign probe_address = probe_register;

    // The levels follow CTRL as written, from the edge after the quad
    // completes.
    initial begin
        csp_held           = 1'b1;     // the CSP starts held: nothing runs until a program is loaded
        test_tone_enable   = 1'b0;
        data_stream_enable = 1'b0;
        stream_source      = '0;
    end
    always_ff @(posedge sclk) begin
        if (to_ctrl) begin
            csp_held           <= quad_data[synth_pkg::CTRL_HOLD];
            test_tone_enable   <= quad_data[synth_pkg::CTRL_TEST_TONE];
            data_stream_enable <= quad_data[synth_pkg::CTRL_DATA_STREAM];
            stream_source      <= quad_data[synth_pkg::CTRL_SOURCE_HIGH:synth_pkg::CTRL_SOURCE_LOW];
        end
    end

    // The door: every quad written to it goes into the FIFO as it is.
    assign fifo_write_enable = quad_complete && quad_address == synth_pkg::MAP_FIFO_DOOR;
    assign fifo_write_quad   = quad_data;

    // IMEM and the ROM: a write lands at the quad's end; the row on the
    // pins is the write's at that edge and the read-back's otherwise, and
    // the read-back's row is the quad after the one streaming (the block
    // answers the clock after).
    wire [synth_pkg::SPI_ADDRESS_W-1:0] imem_offset = quad_address - synth_pkg::MAP_IMEM_BASE;
    assign imem_load_enable = quad_complete && in_imem(quad_address);
    assign imem_row         = imem_offset[csp_pkg::PROGRAM_W:1];
    assign imem_upper       = !imem_offset[0];           // the first quad of a row is its upper half
    assign imem_load_quad   = quad_data;

    wire [synth_pkg::SPI_ADDRESS_W-1:0] rom_offset = quad_address - synth_pkg::MAP_ROM_BASE;
    assign rom_load_enable  = quad_complete && in_rom(quad_address);
    assign rom_row          = rom_offset[csp_pkg::ROM_ADDRESS_W-1:0];
    assign rom_load_word    = quad_data[csp_pkg::ROM_W-1:0];

    //--------------------------------------------------------------------
    // Transmit — falling edge. frame_phase and nonad_index have already
    // advanced at the rising edge that completed the previous nonad, so
    // they index the slot about to stream.
    //--------------------------------------------------------------------
    logic [synth_pkg::SPI_NONAD_W-1:0] tx_nonad;
    always_comb begin
        if (frame_phase == PHASE_COMMAND) begin
            tx_nonad = ID_NONAD;
        end else if (frame_phase != PHASE_DATA || !is_read) begin
            tx_nonad = '0;
        end else begin
            tx_nonad = stream_quad[synth_pkg::SPI_QUAD_W - 1 - synth_pkg::SPI_NONAD_W * nonad_index -: synth_pkg::SPI_NONAD_W];
        end
    end

    logic [synth_pkg::SPI_NONAD_W-1:0] tx_shift;
    initial tx_shift = ID_NONAD;

    always_ff @(negedge sclk or posedge cs) begin
        if (cs) begin
            tx_shift <= ID_NONAD;
        end else if (bit_count == '0) begin
            tx_shift <= tx_nonad;
        end else begin
            tx_shift <= {tx_shift[synth_pkg::SPI_NONAD_W-2:0], 1'b0};
        end
    end

    assign miso = cs ? 1'b0 : tx_shift[synth_pkg::SPI_NONAD_W-1];

endmodule
`default_nettype wire
