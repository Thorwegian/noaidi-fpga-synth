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
// SPI clock writes, the system clock reads. The block is instantiated by
// hand (an SDPB, as the sink area's DPX9B is) in pipeline mode: the entry
// comes out of the block's own output register, two clocks after its
// address, into a register of the queue's own; and its address pin is a
// register of the queue's own, the read pointer's low bits, nothing
// between — both placed beside the block (the place-and-route tool times
// no path into or out of a block RAM's pins; docs/csp_isa.md, 12). The
// entry for a pop is therefore in `head` three clocks after the pop,
// which the core allows for.
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
module csp_write_queue #(
    // the block's site (its three columns and the rows beside it hold the
    // queue's registers, csp_placed_dff.sv); negative leaves it to the placer
    parameter int SITE_X = 19,
    parameter int SITE_Y = 45
) (
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
    output logic [csp_pkg::WORD_W-1:0]          head_data,
    output wire  [9:0]                          read_pointer_gray  // diagnostics: where the CSP has read to
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


    // ---- SPI side ---------------------------------------------------------------
    logic [POINTER_W-1:0] write_pointer;
    logic [POINTER_W-1:0] commit_pointer;
    logic                 commit_toggle;
    logic [POINTER_W-1:0] read_gray_meta, read_gray_sync;
    wire  [POINTER_W-1:0] read_pointer_seen = from_gray(read_gray_sync);

    assign full = (write_pointer - read_pointer_seen) == POINTER_W'(DEPTH);

    wire                  entry_write = write_enable && !full;
    wire [POINTER_W-2:0]  entry_index = write_pointer[POINTER_W-2:0];

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
    assign read_pointer_gray = read_gray;

    // The head entry: the block reads at the read pointer, from a register
    // of the queue's own on its address pin (a copy of read_pointer's low
    // bits, taking the same next value and cleared by the same reset, a
    // clock later: the pop never comes in reset), its pipeline register
    // hands the entry out a clock later, and a register of the queue's own
    // takes it from there, so `head` holds the entry at the read pointer
    // three clocks after the pointer moves: three behind the pop, for a
    // lone pop and for pops on consecutive clocks alike. Both registers
    // are placed beside the block (csp_placed_dff.sv): the tool times no
    // path into or out of the block's pins, and left to itself it put them
    // 43–47 tiles away. (With a mux and an incrementer reading ahead on
    // the pin, the entry came two clocks sooner, and on the board at
    // 73.728 MHz the block sampled the old address on the clock the pop
    // rose: a batch lost its first words after the decoy, the control
    // program's ONE and EIGHTH among them.)
    wire                 pointer_step = pop && committed;
    wire [POINTER_W-2:0] head_index_next = read_pointer[POINTER_W-2:0] + 1'b1;
    logic [POINTER_W-2:0] head_index;   // on the block's address pin
    logic [31:0] pipeline_out;          // the block's pipeline register; the entry is the low 30
    logic [31:0] head;                  // the queue's register after it
    // The queue's flip-flops: the index, then the entry's 30 bits. Flop n goes
    // to tile n / 6, slot n % 6; tile t is column t % 3 of the block's three,
    // row t / 3 of the rows beside the block, nearest first (Y−1, Y+1, Y−2).
    localparam int HEAD_LOW = POINTER_W - 1;
    localparam int FLOPS    = POINTER_W - 1 + ENTRY_W;
    localparam bit PLACED   = SITE_X >= 0 && SITE_Y >= 0;
    localparam     SITE     = $sformatf("X%0dY%0d/BSRAM", SITE_X, SITE_Y);

    function automatic int tile_x(input int t);
        tile_x = PLACED ? SITE_X + t % 3 : -1;
    endfunction
    function automatic int tile_y(input int t);
        tile_y = !PLACED ? -1
               : t / 3 == 0 ? SITE_Y - 1 : t / 3 == 1 ? SITE_Y + 1 : t / 3 == 2 ? SITE_Y - 2 : SITE_Y + 2;
    endfunction

`ifdef SYNTHESIS
    `define CSP_QUEUE_PRIMITIVE
`elsif SIM_GOWIN_PRIM
    `define CSP_QUEUE_PRIMITIVE
`endif
`ifdef CSP_QUEUE_PRIMITIVE
    for (genvar n = 0; n < FLOPS; n++) begin : g_flop
        localparam int X = tile_x(n / 6);
        localparam int Y = tile_y(n / 6);
        if (n < HEAD_LOW) begin : g_index
            csp_placed_dff #(.TILE_X(X), .TILE_Y(Y), .SLOT(n % 6), .HOLDS(1'b1), .CLEARS(1'b1)) u_flop (
                .clk          (clk),
                .clock_enable (pointer_step),
                .clear        (!reset_n),
                .d            (head_index_next[n]),
                .q            (head_index[n])
            );
        end else begin : g_head
            csp_placed_dff #(.TILE_X(X), .TILE_Y(Y), .SLOT(n % 6)) u_flop (
                .clk          (clk),
                .clock_enable (1'b1),
                .clear        (1'b0),
                .d            (pipeline_out[n - HEAD_LOW]),
                .q            (head[n - HEAD_LOW])
            );
        end
    end
    assign head[31:ENTRY_W] = '0;

    // 512 × 32: one block. The address of a 32-bit word is bits [13:5]; on
    // the write side bits [3:0] are the byte-write enables (all four).
    // Instantiated twice over, with the site attribute and without (the
    // placer refuses one naming no site).
    if (PLACED) begin : g_site
    (* BEL = SITE *)
    SDPB #(
        .READ_MODE   (1'b1),         // pipeline: the output register, then one more
        .BIT_WIDTH_0 (32),
        .BIT_WIDTH_1 (32),
        .BLK_SEL_0   (3'b000),
        .BLK_SEL_1   (3'b000),
        .RESET_MODE  ("SYNC")
    ) u_entries (
        .CLKA    (sclk),
        .CEA     (entry_write),
        .RESETA  (1'b0),
        .ADA     ({entry_index, 1'b0, 4'b1111}),
        .DI      ({{(32 - ENTRY_W){1'b0}}, write_address, write_data}),
        .BLKSELA (3'b000),
        .CLKB    (clk),
        .CEB     (1'b1),
        .RESETB  (1'b0),
        .OCE     (1'b1),
        .ADB     ({head_index, 5'b00000}),
        .BLKSELB (3'b000),
        .DO      (pipeline_out)
    );
    end else begin : g_free
    SDPB #(
        .READ_MODE   (1'b1),
        .BIT_WIDTH_0 (32),
        .BIT_WIDTH_1 (32),
        .BLK_SEL_0   (3'b000),
        .BLK_SEL_1   (3'b000),
        .RESET_MODE  ("SYNC")
    ) u_entries (
        .CLKA    (sclk),
        .CEA     (entry_write),
        .RESETA  (1'b0),
        .ADA     ({entry_index, 1'b0, 4'b1111}),
        .DI      ({{(32 - ENTRY_W){1'b0}}, write_address, write_data}),
        .BLKSELA (3'b000),
        .CLKB    (clk),
        .CEB     (1'b1),
        .RESETB  (1'b0),
        .OCE     (1'b1),
        .ADB     ({head_index, 5'b00000}),
        .BLKSELB (3'b000),
        .DO      (pipeline_out)
    );
    end
`else
    // The block and the queue's registers as the benches without the
    // vendor's models see them.
    logic [ENTRY_W-1:0] entries [DEPTH];
    logic [ENTRY_W-1:0] head_read;
    initial begin
        head_index   = '0;
        head_read    = '0;
        pipeline_out = '0;
        head         = '0;
    end
    always_ff @(posedge sclk) begin
        if (entry_write) begin
            entries[entry_index] <= {write_address, write_data};
        end
    end
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            head_index <= '0;
        end else if (pointer_step) begin
            head_index <= head_index_next;
        end
        head_read    <= entries[head_index];
        pipeline_out <= {{(32 - ENTRY_W){1'b0}}, head_read};
        head         <= pipeline_out;
    end
`endif
    assign head_address = head[ENTRY_W-1:csp_pkg::WORD_W];
    assign head_data    = head[csp_pkg::WORD_W-1:0];

endmodule
`default_nettype wire
