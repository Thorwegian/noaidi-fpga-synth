//------------------------------------------------------------------------
// csp_write_queue.sv — firmware register writes, held until the swap
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// docs/csp_isa.md section 2: the firmware's register writes wait here
// with no effect; the CTRL swap commits every write queued so far; the
// CSP applies committed writes in a window at the end of a pass, at most
// 48 per pass, so a program never sees a register change under it and a
// group of writes (a note-on) lands together.
//
// A dual-clock FIFO in one BSRAM (512 entries of address + value): the
// SPI clock writes, the system clock reads.
//
// Crossing the clocks:
//  - The commit point. A swap copies the write pointer into
//    `commit_pointer` and toggles `commit_toggle`. The system clock sees
//    the toggle two flip-flops later and only then reads
//    `commit_pointer`, which has been stable since before the toggle:
//    the payload-behind-a-toggle crossing the first CSP's DMEM mailbox
//    used. Swaps are microseconds apart, far longer than the
//    synchroniser.
//  - The read pointer, back to the SPI side for the full test, crosses
//    Gray-coded through two flip-flops: it only ever steps by one, so one
//    bit changes at a time. The SPI clock runs only during transfers, so
//    the SPI side's copy can lag; it can only look fuller than it is,
//    never emptier, and a write to a full queue is dropped.
//------------------------------------------------------------------------
`default_nettype none
module csp_write_queue (
    // SPI side
    input  wire                                 sclk,
    input  wire                                 sclk_reset_n,
    input  wire                                 write_enable,
    input  wire [csp_pkg::QUEUE_ADDRESS_W-1:0]       write_address,
    input  wire [csp_pkg::WORD_W-1:0]           write_data,
    input  wire                                 swap,          // one sclk cycle
    output logic                                full,

    // system clock side
    input  wire                                 clk,
    input  wire                                 reset_n,
    input  wire                                 pop,           // take the head entry
    output logic                                committed,     // a committed entry waits
    output logic [csp_pkg::QUEUE_ADDRESS_W-1:0]      head_address,
    output logic [csp_pkg::WORD_W-1:0]          head_data
);

    localparam int DEPTH     = 512;
    localparam int POINTER_W = 10;     // one more bit than the index, to tell full from empty
    localparam int ENTRY_W   = csp_pkg::QUEUE_ADDRESS_W + csp_pkg::WORD_W;

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

    logic [ENTRY_W-1:0] entries [DEPTH];

    // ---- SPI side ---------------------------------------------------------------
    logic [POINTER_W-1:0] write_pointer;
    logic [POINTER_W-1:0] commit_pointer;
    logic                 commit_toggle;
    logic [POINTER_W-1:0] read_gray_meta, read_gray_sync;
    wire  [POINTER_W-1:0] read_pointer_seen = from_gray(read_gray_sync);

    assign full = (write_pointer - read_pointer_seen) == POINTER_W'(DEPTH);

    always_ff @(posedge sclk) begin
        if (write_enable && !full) begin
            entries[write_pointer[POINTER_W-2:0]] <= {write_address, write_data};
        end
    end

    always_ff @(posedge sclk or negedge sclk_reset_n) begin
        if (!sclk_reset_n) begin
            write_pointer  <= '0;
            commit_pointer <= '0;
            commit_toggle  <= 1'b0;
            read_gray_meta <= '0;
            read_gray_sync <= '0;
        end else begin
            read_gray_meta <= read_gray;
            read_gray_sync <= read_gray_meta;
            if (write_enable && !full) begin
                write_pointer <= write_pointer + 1'b1;
            end
            if (swap) begin
                // a write in the same cycle as the swap is committed with it
                commit_pointer <= write_pointer + POINTER_W'(write_enable && !full);
                commit_toggle  <= ~commit_toggle;
            end
        end
    end

    // ---- system clock side ------------------------------------------------------------
    logic [POINTER_W-1:0] read_pointer;
    logic [POINTER_W-1:0] read_gray;
    logic [POINTER_W-1:0] committed_pointer;
    logic                 toggle_meta, toggle_sync, toggle_seen;

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
            if (pop && committed) begin
                read_pointer <= read_pointer + 1'b1;
                read_gray    <= to_gray(read_pointer + 1'b1);
            end
        end
    end

    assign committed = read_pointer != committed_pointer;

    // The head entry: a registered BSRAM read that reads ahead to the next
    // entry when popping, so `head` always holds the entry at the read
    // pointer, one clock after the pointer moves.
    logic [ENTRY_W-1:0] head;
    always_ff @(posedge clk) begin
        head <= entries[(pop && committed) ? read_pointer[POINTER_W-2:0] + 1'b1
                                           : read_pointer[POINTER_W-2:0]];
    end
    assign head_address = head[ENTRY_W-1:csp_pkg::WORD_W];
    assign head_data    = head[csp_pkg::WORD_W-1:0];

endmodule
`default_nettype wire
