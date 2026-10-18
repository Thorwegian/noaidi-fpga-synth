//------------------------------------------------------------------------
// spi_bus.sv — the memory-map wire protocol, in nines (docs/memory_map.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Wire format (SPI Mode 0, MSB first, one CS-framed transaction). Every
// block RAM on the chip is 9, 18 or 36 bits wide, so the wire is too:
//
//   nonad 0       the command, 9 bits: [8] 1 = read, 0 = write
//                                       [7] 1 = auto-increment the address per quad
//                                       [6:0] reserved (ignored)
//   nonads 1..2   the address, 18 bits, in quads, MSB first
//   WRITE:  nonads 3..     36-bit quads, four nonads each, streaming
//   READ:   nonads 3..6    one turnaround quad (the fetch's time)
//           nonads 7..     36-bit quads, four nonads each, streaming
//
//   MISO: nonad 0 = the ID nonad (a link check on every frame); the
//   address and turnaround slots = 0; the read slots = the quads read.
//
// What the quads address (docs/memory_map.md): the sixteen system quads
// at 0x00000–0x0000F — CTRL, scratch, the status quads — and, as the
// later issues add them, the FIFO, IMEM, the decode ROM and the pointers.
// Writes outside the ranges are dropped, reads return zero: no aliasing.
//
// Why the read turnaround exists: a read may be served from the system
// clock domain through a synchroniser, and the first data nonad's shift
// register loads half a bit period after the address completes — 12.5 ns
// at the measured 40 MHz ceiling — so without a turnaround the first quad
// could never be fresh. A quad's four nonads give 900 ns at that rate.
// Burst quads prefetch a whole quad early for the same margin.
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

    // ---- the status quads (sclk domain, read-only, 0x8–0xF) --------------
    input  logic [synth_pkg::MAP_SYSTEM_QUADS-synth_pkg::MAP_STORED_QUADS-1:0][synth_pkg::SPI_QUAD_W-1:0] status
);

    //--------------------------------------------------------------------
    // Receive — rising edge; a nonad completes at its ninth bit.
    //--------------------------------------------------------------------
    logic [synth_pkg::SPI_NONAD_W-2:0] rx_shift;
    logic [3:0]              bit_count;

    wire [synth_pkg::SPI_NONAD_W-1:0] rx_nonad  = {rx_shift, mosi};
    wire                    nonad_end = bit_count == 4'(synth_pkg::SPI_NONAD_W - 1);

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
    // The system quads: read back from the sclk domain, so a read needs
    // no clock crossing. CTRL (0x2) keeps what was written, less the swap
    // request, which is an event and not a state.
    //--------------------------------------------------------------------
    localparam int STATUS_QUADS = synth_pkg::MAP_SYSTEM_QUADS - synth_pkg::MAP_STORED_QUADS;

    logic [synth_pkg::SPI_QUAD_W-1:0] system_quad [synth_pkg::MAP_STORED_QUADS];
    initial begin
        for (int quad = 0; quad < synth_pkg::MAP_STORED_QUADS; quad++) system_quad[quad] = '0;
    end

    function automatic logic [synth_pkg::SPI_QUAD_W-1:0] quad_at(input logic [synth_pkg::SPI_ADDRESS_W-1:0] address);
        if (address < synth_pkg::SPI_ADDRESS_W'(synth_pkg::MAP_STORED_QUADS)) begin
            quad_at = system_quad[address[2:0]];
        end else if (address < synth_pkg::SPI_ADDRESS_W'(synth_pkg::MAP_SYSTEM_QUADS)) begin
            quad_at = status[address[2:0]];
        end else begin
            quad_at = '0;
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

    phase_e                  frame_phase;
    logic                    is_read, auto_increment;
    logic [synth_pkg::SPI_ADDRESS_W-1:0] quad_address;
    logic [1:0]              nonad_index;    // the nonad within the current quad
    logic [synth_pkg::SPI_QUAD_W-synth_pkg::SPI_NONAD_W-1:0] partial_quad;   // the quad's first three nonads
    logic [synth_pkg::SPI_QUAD_W-1:0]   stream_quad;     // the quad streaming out NOW

    initial begin
        frame_phase    = PHASE_COMMAND;
        is_read        = 1'b0;
        auto_increment = 1'b0;
        quad_address   = '0;
        nonad_index   = '0;
        partial_quad   = '0;
        stream_quad    = '0;
    end

    // The quad read next: from the address just completed (its low nonad
    // is on the wire) or from the next quad of a burst. One quad_at call,
    // so that there is one copy of its multiplexers.
    wire [synth_pkg::SPI_ADDRESS_W-1:0] next_read_address =
        frame_phase == PHASE_ADDRESS_LOW ? {quad_address[synth_pkg::SPI_ADDRESS_W-1:synth_pkg::SPI_NONAD_W], rx_nonad}
                                         : (auto_increment ? quad_address + 1'b1 : quad_address);

    wire last_nonad_of_quad = nonad_index == 2'(synth_pkg::SPI_NONADS_PER_QUAD - 1);

    always_ff @(posedge sclk or posedge cs) begin
        if (cs) begin
            frame_phase  <= PHASE_COMMAND;
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
                    quad_address[synth_pkg::SPI_NONAD_W-1:0] <= rx_nonad;
                    stream_quad  <= quad_at(next_read_address);
                    nonad_index <= '0;
                    frame_phase  <= is_read ? PHASE_TURNAROUND : PHASE_DATA;
                end
                PHASE_TURNAROUND: begin                  // one quad's worth of nonads
                    nonad_index <= nonad_index + 2'd1;
                    if (last_nonad_of_quad) begin
                        frame_phase <= PHASE_DATA;
                    end
                end
                PHASE_DATA: begin
                    partial_quad <= {partial_quad[synth_pkg::SPI_QUAD_W-2*synth_pkg::SPI_NONAD_W-1:0], rx_nonad};
                    nonad_index <= nonad_index + 2'd1;
                    if (last_nonad_of_quad) begin
                        stream_quad <= quad_at(next_read_address);    // the next quad of a burst
                        if (auto_increment) begin
                            quad_address <= quad_address + 1'b1;
                        end
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

    wire in_system = quad_complete && quad_address < synth_pkg::SPI_ADDRESS_W'(synth_pkg::MAP_SYSTEM_QUADS);
    wire to_ctrl   = in_system && quad_address == synth_pkg::MAP_CTRL;

    // CTRL: the swap is an event; the rest are levels.
    assign swap = to_ctrl && quad_data[synth_pkg::CTRL_SWAP];

    always_ff @(posedge sclk) begin
        if (in_system && quad_address[3] == 1'b0) begin
            system_quad[quad_address[2:0]] <= to_ctrl ? quad_data & ~(synth_pkg::SPI_QUAD_W'(1) << synth_pkg::CTRL_SWAP) : quad_data;
        end
    end

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
