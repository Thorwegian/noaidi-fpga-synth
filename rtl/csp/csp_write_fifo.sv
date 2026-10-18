//------------------------------------------------------------------------
// csp_write_fifo.sv — the firmware's register writes, from the SPI clock
//                     to the pass's write window
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The one queue in the system (docs/csp2_architecture.md section 2): one
// SDPX9B of 512 × 36, port A written from the door on the SPI clock, a
// quad an entry as it came over the wire — the register or sink address
// in bits 35:24, the word in 23:6 — and port B read on the system clock
// in pipeline mode (the entry is in the block's output register two
// clocks after its address). A swap commits everything written so far;
// the window pops committed entries, and a write to a full FIFO is
// dropped and counted. It holds 511 quads: the 512th row is the one the
// parked reader sits on.
//
// The two ports never meet on a row (UG285-1.4E p24, note 1):
//  - with entries committed, the reader's address is the head, a row the
//    writer filled before the commit and cannot reach again until the
//    FIFO has wrapped full, which the full flag forbids;
//  - with none, the reader's address parks one row BEHIND the head, the
//    last row consumed — not the row the next write takes. The first
//    revision parked on the head and lost a batch's first word to that
//    row until a decoy write covered it; the decoy is gone.
//
// The crossings are single bits: the commit is a toggle, with the commit
// pointer stable since before it; the read pointer goes back Gray-coded,
// one bit changing at a time. The firmware's writes are microseconds
// apart, far longer than the synchronisers.
//
// Pops are pipelined: a pop at clock t moves the pointer, and the entry
// is on `head_quad` at t+2 (the block's address register samples the
// head's row at the pop's edge, its output register holds the entry a
// clock later), for a lone pop and for pops on consecutive clocks alike. The window
// counts pops it may make from `committed` and takes the quads as they
// arrive, `head_valid` marking each.
//------------------------------------------------------------------------
`default_nettype none
module csp_write_fifo (
    // ---- the SPI side (sclk) ----
    input  wire                             sclk,
    input  wire                             sclk_reset_n,
    input  wire                             write_enable,       // a quad for the door
    input  wire [csp_pkg::QUAD_W-1:0]       write_quad,
    input  wire                             swap,               // one sclk cycle: commit
    output logic                            full,
    output logic [15:0]                     dropped,            // writes to a full FIFO, saturating

    // ---- the system clock side ----
    input  wire                             clk,
    input  wire                             reset_n,
    input  wire                             pop,                // take the head entry
    output logic                            committed,          // a committed entry waits
    output logic                            head_valid,         // head_quad is a popped entry
    output logic [csp_pkg::QUAD_W-1:0]      head_quad,
    output wire  [csp_pkg::FIFO_POINTER_W-1:0] read_pointer_gray   // diagnostics
);

    localparam int POINTER_W = csp_pkg::FIFO_POINTER_W;
    localparam int INDEX_W   = POINTER_W - 1;

    function automatic logic [POINTER_W-1:0] to_gray(input logic [POINTER_W-1:0] binary);
        to_gray = binary ^ (binary >> 1);
    endfunction

    function automatic logic [POINTER_W-1:0] from_gray(input logic [POINTER_W-1:0] gray);
        logic [POINTER_W-1:0] binary;
        binary[POINTER_W-1] = gray[POINTER_W-1];
        for (int bit_index = POINTER_W - 2; bit_index >= 0; bit_index--) begin
            binary[bit_index] = binary[bit_index + 1] ^ gray[bit_index];
        end
        from_gray = binary;
    endfunction

    // ---- the SPI side --------------------------------------------------------
    logic [POINTER_W-1:0] write_pointer;
    logic [POINTER_W-1:0] commit_pointer;
    logic                 commit_toggle;
    logic [POINTER_W-1:0] read_gray_meta, read_gray_sync;
    wire  [POINTER_W-1:0] read_pointer_seen = from_gray(read_gray_sync);

    // Full one entry early: the row behind the reader is the parked
    // address, and the writer must never reach it.
    assign full = (write_pointer - read_pointer_seen) >= POINTER_W'(csp_pkg::FIFO_DEPTH - 1);

    wire                entry_write = write_enable && !full;
    wire [INDEX_W-1:0]  entry_index = write_pointer[INDEX_W-1:0];

    always_ff @(posedge sclk or negedge sclk_reset_n) begin
        if (!sclk_reset_n) begin
            write_pointer  <= '0;
            commit_pointer <= '0;
            commit_toggle  <= 1'b0;
            read_gray_meta <= '0;
            read_gray_sync <= '0;
            dropped        <= '0;
        end else begin
            read_gray_meta <= read_gray;
            read_gray_sync <= read_gray_meta;
            if (entry_write) begin
                write_pointer <= write_pointer + 1'b1;
            end
            if (write_enable && full && dropped != '1) begin
                dropped <= dropped + 1'b1;
            end
            if (swap) begin
                // a write in the same cycle as the swap is committed with it
                commit_pointer <= write_pointer + POINTER_W'(entry_write);
                commit_toggle  <= ~commit_toggle;
            end
        end
    end

    // ---- the system clock side -----------------------------------------------
    logic [POINTER_W-1:0] read_pointer;
    logic [POINTER_W-1:0] read_gray;
    logic [POINTER_W-1:0] committed_pointer;
    logic                 toggle_meta, toggle_sync, toggle_seen;

    assign committed = read_pointer != committed_pointer;
    wire pointer_step = pop && committed;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            read_pointer      <= '0;
            read_gray         <= '0;
            committed_pointer <= '0;
            toggle_meta       <= 1'b0;
            toggle_sync       <= 1'b0;
            toggle_seen       <= 1'b0;
        end else begin
            toggle_meta <= commit_toggle;
            toggle_sync <= toggle_meta;
            if (toggle_sync != toggle_seen) begin
                toggle_seen       <= toggle_sync;
                committed_pointer <= commit_pointer;   // stable since before the toggle
            end
            if (pointer_step) begin
                read_pointer <= read_pointer + 1'b1;
                read_gray    <= to_gray(read_pointer + 1'b1);
            end
        end
    end
    assign read_pointer_gray = read_gray;

    // The reader's address: the head while entries wait, one row behind it
    // otherwise. It is a register of its own on the block's address pin,
    // taking the value the pointer will have after this clock's pop.
    logic [INDEX_W-1:0] read_index;
    wire  [POINTER_W-1:0] pointer_next = read_pointer + POINTER_W'(pointer_step);
    wire  committed_next = pointer_next != committed_pointer;
    wire  [POINTER_W-1:0] parked = pointer_next - 1'b1;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) read_index <= '1;                               // one behind row 0
        else          read_index <= committed_next ? pointer_next[INDEX_W-1:0] : parked[INDEX_W-1:0];
    end

    // A popped entry reaches head_quad two clocks after its pop.
    logic [1:0] pop_pipe;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) pop_pipe <= '0;
        else          pop_pipe <= {pop_pipe[0], pointer_step};
    end
    assign head_valid = pop_pipe[1];

`ifdef SYNTHESIS
    // A 36-bit entry's address is AD[13:5] (UG285-1.4E p4, table 2-2); the
    // four low bits of ADA are the write's lane enables, all on.
    SDPX9B #(
        .READ_MODE   (1'b1),         // pipeline: the block's output register
        .BIT_WIDTH_0 (36),
        .BIT_WIDTH_1 (36),
        .BLK_SEL_0   (3'b000),
        .BLK_SEL_1   (3'b000),
        .RESET_MODE  ("SYNC")
    ) u_entries (
        .CLKA    (sclk),
        .CEA     (entry_write),
        .RESETA  (1'b0),
        .ADA     ({entry_index, 1'b0, 4'b1111}),
        .DI      (write_quad),
        .BLKSELA (3'b000),
        .CLKB    (clk),
        .CEB     (1'b1),
        .RESETB  (1'b0),
        .OCE     (1'b1),
        .ADB     ({read_index, 5'b00000}),
        .BLKSELB (3'b000),
        .DO      (head_quad)
    );
`else
    // The block as the benches see it: the array, the address register's
    // read, and the pipeline register after it.
    logic [csp_pkg::QUAD_W-1:0] entries [csp_pkg::FIFO_DEPTH];
    logic [csp_pkg::QUAD_W-1:0] read_stage;
    initial begin
        for (int entry = 0; entry < csp_pkg::FIFO_DEPTH; entry++) entries[entry] = '0;
        read_stage = '0;
        head_quad  = '0;
    end
    always_ff @(posedge sclk) begin
        if (entry_write) entries[entry_index] <= write_quad;
    end
    always_ff @(posedge clk) begin
        read_stage <= entries[read_index];
        head_quad  <= read_stage;
    end
`endif

endmodule
`default_nettype wire
