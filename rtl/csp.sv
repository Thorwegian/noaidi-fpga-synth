//------------------------------------------------------------------------
// csp.sv -- the modulation bus and its source sequencer (#136)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Split out of element_pipeline.sv, which was carrying two unrelated
// jobs in 1,473 lines: the element DSP lane pipeline, and this. They
// shared a file because they shared the drum schedule -- the sequencer was
// armed at slot 299 purely so its writes could not collide with lane
// reads on a single-ported RAM. #134 removed that coupling by
// double-buffering the bus generation, so the two are now genuinely
// independent: this module references the drum's slot counter nowhere.
//
// What lives here: the six bus replicas plus dmem_init and dmem_local,
// the SPI mailbox, the ping-pong generation bit, the source table and
// state RAMs, the sequencer state machine, the LFO and ADSR step logic,
// and the chain-summing arithmetic.
//
// The interface to the lane pipeline is six read ports: an address in
// (from the S1 pointers) and registered data out (landing at S2),
// which is exactly the timing the pipeline had when the RAMs were
// inline.
//------------------------------------------------------------------------
`default_nettype none
module csp (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         sample_tick,
    input  wire         sclk,
    input  wire         bank_active,
    input  wire         bank_shadow,

    // SPI bus-base mailbox (sclk domain, crossed by a toggle)
    input  wire [9:0]   dmem_wr_addr,
    input  wire [17:0]  dmem_wr_data,
    input  wire         dmem_wr_toggle,

    // SPI source-table writes
    input  wire         imem_write_enable,
    input  wire [9:0]   imem_write_addr,
    input  wire [31:0]  imem_write_data,

    // Six sink read ports -- address in at S1, data out at S2
    input  wire [8:0]   rd_pitch_a,
    input  wire [8:0]   rd_duty_a,
    input  wire [8:0]   rd_fc_a,
    input  wire [8:0]   rd_q_a,
    input  wire [8:0]   rd_gl_a,
    input  wire [8:0]   rd_gr_a,
    output logic signed [17:0] rd_pitch_d,
    output logic signed [17:0] rd_duty_d,
    output logic signed [17:0] rd_fc_d,
    output logic signed [17:0] rd_q_d,
    output logic signed [17:0] rd_gl_d,
    output logic signed [17:0] rd_gr_d,

    output logic        test_tone_en
);
    //----------------------------------------------------------------
    // Bus RAM — the uniform Q8.10 pool (bus_architecture.md).
    // One replica in the B1 pilot (only cutoff reads it); replicas
    // are added per sink at B2. Written ONLY on sysclk: SPI writes
    // arrive through the toggle mailbox below and commit in an idle
    // slot (lane bus reads issue during slots 1..~257, so a commit at
    // slot >258 can never collide with a read — the BSRAM
    // read-during-write corruption class is impossible by schedule).
    // Bus 0 is hardwired zero (writes to it are ignored).
    //----------------------------------------------------------------
    // Six replicas of the one uniform pool — one read port per sink
    // (see bus_architecture.md "Why six replicas"). Broadcast writes
    // keep them identical.
    reg signed [17:0] dmem_pitch [0:2*synth_pkg::DMEM_WORDS-1];
    reg signed [17:0] dmem_duty  [0:2*synth_pkg::DMEM_WORDS-1];
    reg signed [17:0] dmem_fc    [0:2*synth_pkg::DMEM_WORDS-1];
    reg signed [17:0] dmem_q     [0:2*synth_pkg::DMEM_WORDS-1];
    reg signed [17:0] dmem_gl    [0:2*synth_pkg::DMEM_WORDS-1];
    reg signed [17:0] dmem_gr    [0:2*synth_pkg::DMEM_WORDS-1];
    integer bi;
    // BOTH generations -- the arrays are 2*DMEM_WORDS deep (#134) and an
    // uninitialised shadow half reads X the first time dmem_gen flips.
    initial for (bi = 0; bi < 2*synth_pkg::DMEM_WORDS; bi = bi + 1) begin
        dmem_pitch[bi] = 18'sd0;
        dmem_duty[bi]  = 18'sd0;
        dmem_fc[bi]    = 18'sd0;
        dmem_q[bi]     = 18'sd0;
        dmem_gl[bi]    = 18'sd0;
        dmem_gr[bi]    = 18'sd0;
    end

    // SPI bus-base writes now land in a dedicated BASE RAM as well as
    // the value replicas: sinks read the replicas, the program counter
    // reads the base and writes base + contribution into the replicas
    // (the spec's "bus = base register + instruction contributions",
    // realized). A bus no instruction targets keeps value = base via the
    // mailbox's own replica write.
    reg signed [17:0] dmem_init [0:2*synth_pkg::DMEM_WORDS-1];
    // SECOND COPY, for the same reason imem was split: the sequencer needs
    // TWO different addresses out of the init image in one cycle -- the
    // watched gate bus (from CFG) and the target's base (from the
    // destination field). One port served both by phase muxing, which cost
    // a cycle. Written by the identical mailbox strobe, so the two are
    // always the same memory; only the read address differs.
    reg signed [17:0] dmem_gate [0:2*synth_pkg::DMEM_WORDS-1];
    integer bbi;
    initial for (bbi = 0; bbi < 2*synth_pkg::DMEM_WORDS; bbi = bbi + 1) begin
        dmem_init[bbi] = 18'sd0;
        dmem_gate[bbi] = 18'sd0;
    end

    // BUS-SUM RAM (#92/#98): the sequencer-facing mirror of a bus's
    // OUTPUT SUM — written by the same strobes as the replicas, read
    // at P1 by SEND entries. This is what makes the node graph's
    // edges real (Thor, #98): a send references the bus's summed
    // output (firmware base + every source contribution written so
    // far), not the firmware base alone. With sources ordered before
    // their sends in the table, propagation is same-sample.
    reg signed [17:0] dmem_local [0:2*synth_pkg::DMEM_WORDS-1];
    integer bsi;
    initial for (bsi = 0; bsi < 2*synth_pkg::DMEM_WORDS; bsi = bsi + 1)
        dmem_local[bsi] = 18'sd0;

    // Program counter replica-write strobes (driven below)
    logic               dmem_we;
    logic [9:0]         dmem_waddr;
    logic signed [17:0] dmem_wdata;

    // #134: ping-pong generation bit. The sequencer writes generation
    // ~dmem_gen while the pipeline reads dmem_gen, and they swap at the
    // sample boundary -- so every element sees one coherent generation
    // and a read can never collide with a write. Costs no extra BSRAM:
    // the second generation lives in the half of each block that the
    // 512-entry pool leaves unused.
    logic dmem_gen;   // flipped once per sample by the process below

    logic dmem_wr_toggle_meta, dmem_wr_toggle_sync, dmem_wr_toggle_prev;
    logic dmem_mbox_pending;
    logic [9:0]  dmem_mbox_addr;
    logic [17:0] dmem_mbox_data;
    // #134: a mailbox entry commits over TWO takes, one per generation.
    // The sequencer rewrites its target buses every sample, so ITS writes
    // can live in one half. A mailbox write sets a PERSISTENT base that
    // nothing refreshes, so a single-half write alternates with stale
    // data on every swap -- silence, in practice (caught by
    // tb_prog_pingpong's persistence check). dmem_commit_half latches the
    // half written first, so a sample boundary falling between the two
    // takes cannot make the second write repeat it.
    //
    // This does not weaken atomicity where it matters: the property we
    // need is that the WALKER's sweep is seen as one complete
    // generation. Firmware writes were always asynchronous and
    // mid-sample, before ping-pong and after it.
    logic dmem_commit_phase;
    logic dmem_commit_half;
    // Mailbox commits happen in any idle slot where the sequencer is not
    // writing the replicas THIS cycle (dmem_we below): lane reads issue
    // during slots 1..~257, and a commit colliding with a sequencer
    // write simply defers one cycle. The window stays ~500 slots
    // wide, so a 10 MHz SPI burst can never overrun the 1-deep
    // mailbox (word period 5.6 us >> max wait).
    // dmem_mbox_take is the SINGLE condition for both committing and
    // clearing pending. An earlier version cleared pending on
    // dmem_wr_window alone while the commit also required !dmem_we — when a
    // write's first idle cycle coincided with a sequencer write (~1 in
    // 3 during the sequencer span), the write was silently dropped:
    // a lost gate-off was a stuck note, a lost gate-on a dead key.
    // #134: ping-pong put reads and writes in different generations,
    // so the window that used to keep them apart by schedule is gone.
    // A commit still defers a cycle when the sequencer is writing, since
    // they share the write port.
    wire  dmem_wr_window   = 1'b1;
    wire  dmem_mbox_take   = dmem_mbox_pending && dmem_wr_window && !dmem_we;
    wire  dmem_commit = dmem_mbox_take && (dmem_mbox_addr != 10'd0);
    wire  dmem_commit_half_sel = dmem_commit_phase ? ~dmem_commit_half : ~dmem_gen;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dmem_wr_toggle_meta <= 1'b0; dmem_wr_toggle_sync <= 1'b0; dmem_wr_toggle_prev <= 1'b0;
            dmem_mbox_pending <= 1'b0;
            dmem_mbox_addr <= '0; dmem_mbox_data <= '0;
        end else begin
            dmem_wr_toggle_meta <= dmem_wr_toggle; dmem_wr_toggle_sync <= dmem_wr_toggle_meta; dmem_wr_toggle_prev <= dmem_wr_toggle_sync;
            if (dmem_wr_toggle_sync != dmem_wr_toggle_prev) begin
                dmem_mbox_pending <= 1'b1;         // payload is stable: it was
                dmem_mbox_addr   <= dmem_wr_addr;      // written before the toggle,
                dmem_mbox_data   <= dmem_wr_data;      // 2 sync FFs ago
            end else if (dmem_mbox_take && dmem_commit_phase) begin
                dmem_mbox_pending <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dmem_commit_phase <= 1'b0;
            dmem_commit_half  <= 1'b0;
        end else if (dmem_mbox_take) begin
            if (!dmem_commit_phase) begin
                dmem_commit_half  <= ~dmem_gen;   // the half written now
                dmem_commit_phase <= 1'b1;
            end else
                dmem_commit_phase <= 1'b0;
        end
    end

    always_ff @(posedge clk)
        if (dmem_commit) dmem_init[dmem_mbox_addr] <= $signed(dmem_mbox_data);
    always_ff @(posedge clk)
        if (dmem_commit) dmem_gate[dmem_mbox_addr] <= $signed(dmem_mbox_data);

    // Bus 1023 doubles as the test-tone control latch (issue #81).
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)                                       test_tone_en <= 1'b0;
        else if (dmem_commit && dmem_mbox_addr == 10'd1023)
            test_tone_en <= dmem_mbox_data[0];

    // Replica writes: one physical port, two writers — the sequencer
    // owns its cycle (dmem_we), the mailbox defers around it.
    always_ff @(posedge clk)
        if (dmem_commit)   dmem_pitch[{dmem_commit_half_sel, dmem_mbox_addr[8:0]}] <= $signed(dmem_mbox_data);
        else if (dmem_we)   dmem_pitch[{~dmem_gen, dmem_waddr[8:0]}]   <= dmem_wdata;
    always_ff @(posedge clk)
        if (dmem_commit)   dmem_duty[{dmem_commit_half_sel, dmem_mbox_addr[8:0]}] <= $signed(dmem_mbox_data);
        else if (dmem_we)   dmem_duty[{~dmem_gen, dmem_waddr[8:0]}]   <= dmem_wdata;
    always_ff @(posedge clk)
        if (dmem_commit)   dmem_fc[{dmem_commit_half_sel, dmem_mbox_addr[8:0]}] <= $signed(dmem_mbox_data);
        else if (dmem_we)   dmem_fc[{~dmem_gen, dmem_waddr[8:0]}]   <= dmem_wdata;
    always_ff @(posedge clk)
        if (dmem_commit)   dmem_q[{dmem_commit_half_sel, dmem_mbox_addr[8:0]}] <= $signed(dmem_mbox_data);
        else if (dmem_we)   dmem_q[{~dmem_gen, dmem_waddr[8:0]}]   <= dmem_wdata;
    always_ff @(posedge clk)
        if (dmem_commit)   dmem_gl[{dmem_commit_half_sel, dmem_mbox_addr[8:0]}] <= $signed(dmem_mbox_data);
        else if (dmem_we)   dmem_gl[{~dmem_gen, dmem_waddr[8:0]}]   <= dmem_wdata;
    always_ff @(posedge clk)
        if (dmem_commit)   dmem_gr[{dmem_commit_half_sel, dmem_mbox_addr[8:0]}] <= $signed(dmem_mbox_data);
        else if (dmem_we)   dmem_gr[{~dmem_gen, dmem_waddr[8:0]}]   <= dmem_wdata;
    always_ff @(posedge clk)
        if (dmem_commit)   dmem_local[dmem_mbox_addr] <= $signed(dmem_mbox_data);
        else if (dmem_we)   dmem_local[dmem_waddr]  <= dmem_wdata;

    //----------------------------------------------------------------
    // Program counter (B4/B5, bus_architecture.md) -- the table executor.
    // 256 entries x 3 config words (stride 4 in the RAM), ONE cycle per
    // entry since #138; the six-stage pipeline is documented at the pc
    // below. Law 1: the one instruction multiply sits alone in its stage
    // with registered operands. Law 3: entries execute in table order, once
    // per sample. An instruction's OUTPUT uses the PREVIOUS sample's state --
    // the one-sample lag is inaudible at control rates and it keeps both the
    // sine's internal multiply and the instruction multiply fed by registers
    // only.
    //
    // ADSR state word: [28:27] stage (0 idle, 1 attack, 2 decay/sustain,
    // 3 release), [26:0] level in UQ22.5. Gate is LEVEL-sensitive on the
    // watched bus (> 0 = held), so note-on/off is one live bus write.
    //
    // FIVE fractional bits since #138, not four. A pass runs every sample
    // now instead of every other one, so an unchanged step would have halved
    // every envelope time. One more fractional bit restores the wall-clock
    // rate exactly while keeping all 256 codes distinct -- halving the
    // decoded step instead would collide codes in pairs at high4 = 0 and
    // break the equal-ratio ladder.
    //----------------------------------------------------------------
    localparam [1:0] AST_IDLE = 2'd0, AST_ATT = 2'd1,
                     AST_DEC  = 2'd2, AST_REL = 2'd3;

    // THE 3-CYCLE BOTTLENECK, REMOVED (#138). This was one RAM holding
    // {bank, entry, word} and read through a single port with the address
    // muxed by phase: CFG at P0, RATES at P1, DEPTH at P2. Three words
    // through one port costs three cycles however the logic is arranged, so
    // the instruction rate was capped at one per three cycles regardless of
    // how well the stages overlapped.
    //
    // Three RAMs, same total bits, read with the SAME address in the SAME
    // cycle. The SPI write path is unchanged from the firmware's point of
    // view: imem_write_addr is still {entry[7:0], word[1:0]} and the low two
    // bits now select which RAM the word lands in.
    reg [31:0] imem_cfg   [0:2*synth_pkg::NUM_INSTR-1];   // {bank, entry[7:0]}
    reg [31:0] imem_rate  [0:2*synth_pkg::NUM_INSTR-1];
    reg [31:0] imem_depth [0:2*synth_pkg::NUM_INSTR-1];
    // State word: LFO uses [23:0] as its phase; ADSR uses [27:26] as
    // the stage and [25:0] as the level in UQ22.4 — FOUR FRACTIONAL
    // BITS, so rate increments are in 1/16-LSB units and the 8-bit
    // log2 rate byte decodes as ONE uniform expression with no
    // truncation anywhere: all 256 codes are distinct equal-ratio
    // steps (Thor's perceptual-linearity rule; a MIDI CC maps as
    // cc << 1). The fractional bits ARE the "binary point moved four
    // left" — in the accumulator, where it belongs.
    reg [28:0] istate [0:synth_pkg::NUM_INSTR-1];
    integer wi;
    initial begin
        for (wi = 0; wi < 2*synth_pkg::NUM_INSTR; wi = wi + 1) begin
            imem_cfg[wi]   = 32'd0;            // opcode 0 = off
            imem_rate[wi]  = 32'd0;
            imem_depth[wi] = 32'd0;
        end
        for (wi = 0; wi < synth_pkg::NUM_INSTR; wi = wi + 1)
            istate[wi] = 29'd0;
    end

    // Route the word to its RAM by the low address bits. Same wire format.
    wire [8:0] imem_wr_entry = {bank_shadow, imem_write_addr[9:2]};
    always_ff @(posedge sclk)
        if (imem_write_enable) begin
            case (imem_write_addr[1:0])
                2'd0: imem_cfg[imem_wr_entry]   <= imem_write_data;
                2'd1: imem_rate[imem_wr_entry]  <= imem_write_data;
                2'd2: imem_depth[imem_wr_entry] <= imem_write_data;
                default: ;                      // word 3 unused (stride 4)
            endcase
        end

    // ONE INSTRUCTION PER CYCLE (#138). Six stages, one instruction deep
    // each, retiring one per cycle once full:
    //
    //   F  present pc to imem_cfg/rate/depth and istate
    //   D  those four are out; present the gate/source address (from CFG)
    //      and the target address to dmem_gate / dmem_local / dmem_init
    //   R  gate, send-source and target base are out; decode the rate
    //      bytes, resolve the gate, choose the operand
    //   X  the instruction multiply -- registered operands, alone in its
    //      stage (law 1) -- and the state writeback
    //   A  value = addend + contribution, saturated
    //   W  write the replicas
    //
    // FULL RATE IS BACK. #100 put the sequencer on half rate because
    // 256 instructions x 3 cycles = 768 did not fit beside the lane
    // pipeline in a 768-cycle sample. At one per cycle a full 256-entry
    // pass costs 256 cycles, so every instruction runs every sample: 96 kHz
    // control instead of 48, and the allocator's "a chain must live inside
    // one half" rule is gone along with pc_half itself.
    //
    // Field map, unchanged from the 3-cycle version so the firmware format
    // is untouched (traced from the old phase-delayed reads):
    //   CFG   [3:0] opcode, [5:4] LFO shape, [15:6] target, [25:16] source
    //         bus (also the ADSR's watched gate), [31:16] LFO phase
    //         increment -- overlapping the source field, which an LFO does
    //         not use
    //   RATES [7:0] attack, [15:8] decay, [23:16] sustain LEVEL, [31:24]
    //         release -- the universal A, D, S, R order
    //   DEPTH [17:0] signed coefficient, 0x10000 = unity
    logic [8:0] pc;             // 0..NUM_INSTR, one per cycle

    // The generation now flips once per SAMPLE, because a complete pass is
    // once per sample again. Under half rate it had to flip every other
    // sample (a pass spanned two), and flipping early published a
    // half-written generation -- halved depth and a stale link in any chain.
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)           dmem_gen <= 1'b0;
        else if (sample_tick) dmem_gen <= ~dmem_gen;

    wire pc_active = (pc < 9'(synth_pkg::NUM_INSTR));
    // Drain: the last instruction fetched still has to reach W, which is the
    // full pipeline depth now rather than the 2 slots the 3-cycle version
    // needed. Without it the final entries' writes never land -- #97's
    // stale-cutoff bug was exactly this off-by-a-pipeline-length.
    localparam int PIPE_DRAIN = 5;
    logic [2:0] drain_cnt;
    wire pc_running = pc_active || (drain_cnt != 3'd0);
    wire [7:0] pc_addr = pc[7:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc <= 9'(synth_pkg::NUM_INSTR); drain_cnt <= 3'd0;
        end else if (sample_tick) begin
            pc <= 9'd0; drain_cnt <= 3'(PIPE_DRAIN);
        end else if (pc_running) begin
            if (pc_active) pc <= pc + 9'd1;
            else if (drain_cnt != 3'd0) drain_cnt <= drain_cnt - 3'd1;
        end
    end

    // ---- RAM outputs, all arriving in the same cycle --------------------
    logic [31:0] cfg_q, rate_q, depth_q;
    logic [28:0] istate_q;
    logic signed [17:0] gate_q, src_q, base_q;
    logic [7:0]  pc_addr_d;     // the pc that goes with cfg_q
    logic        d_valid;

    // ---- D stage registers ---------------------------------------------
    logic        r_valid;
    logic [7:0]  r_pc;
    logic [3:0]  r_opcode;
    // decoded enables, so no stage switches on the opcode value
    wire r_src_en = r_opcode[synth_pkg::OPC_SOURCE];
    wire r_st_en  = r_opcode[synth_pkg::OPC_STATE];
    wire r_mul_en = r_opcode[synth_pkg::OPC_MUL];
    wire r_acc_en = r_opcode[synth_pkg::OPC_ACCUM];
    wire r_is_env = r_st_en &&  r_src_en;     // watches a gate -> envelope
    wire r_is_lfo = r_st_en && !r_src_en;     // free-running phase
    logic [1:0]  r_shape;
    logic [9:0]  r_dest, r_src;
    logic [15:0] r_lfo_rate;
    logic [31:0] r_rate, r_depth;
    logic [28:0] r_istate;

    // ---- R stage registers ---------------------------------------------
    logic        x_valid;
    logic [7:0]  x_pc;
    logic [3:0]  x_opcode;
    wire x_st_en  = x_opcode[synth_pkg::OPC_STATE];
    wire x_mul_en = x_opcode[synth_pkg::OPC_MUL];
    wire x_acc_en = x_opcode[synth_pkg::OPC_ACCUM];
    wire x_is_lfo = x_st_en && !x_opcode[synth_pkg::OPC_SOURCE];
    logic [9:0]  x_dest;
    logic [28:0] x_istate;
    logic signed [17:0] x_operand, x_depth, x_base;
    logic        x_gate;
    logic [15:0] x_lfo_rate;
    logic [20:0] x_attack_step, x_decay_step, x_release_step;
    logic [26:0] x_sustain_target;

    // ---- X stage registers ---------------------------------------------
    logic        a_valid;
    logic        a_acc_en;
    logic [9:0]  a_dest;
    logic signed [17:0] a_base;
    logic signed [35:0] a_product;

    // ---- A stage registers: the write ----------------------------------
    logic        wb_valid;
    logic [9:0]  wb_addr;
    logic signed [17:0] wb_value;

    //----------------------------------------------------------------
    // FORWARDING. At three cycles per instruction there was slack enough
    // that comparing against the immediately previous entry covered every
    // case, which is why the allocator had to group sources sharing a target
    // into adjacent slots. At one per cycle several instructions are in
    // flight, so a short history of completed results is kept and the MOST
    // RECENT match wins. That relaxes the allocator rule rather than
    // tightening it: a chain now tolerates gaps of up to three slots.
    //
    // The base read needs no hazard logic -- dmem_init is the pass's initial
    // image and only the SPI mailbox ever writes it.
    //----------------------------------------------------------------
    logic        h1_valid, h2_valid;
    logic [9:0]  h1_addr,  h2_addr;
    logic signed [17:0] h1_value, h2_value;

    wire signed [19:0] result = a_product[35:16];
    // bit 3 makes chaining EXPLICIT. It used to be inferred from program
    // order -- adjacent entries sharing a target summed, scattered ones did
    // last-write-wins -- which is a correctness rule the allocator could not
    // check. With the bit clear an instruction always starts from the
    // target's initial value, whatever its neighbours do.
    wire signed [17:0] accum_in =
          (a_acc_en && wb_valid && wb_addr == a_dest) ? wb_value
        : (a_acc_en && h1_valid && h1_addr == a_dest) ? h1_value
        : (a_acc_en && h2_valid && h2_addr == a_dest) ? h2_value
        :                                               a_base;
    wire signed [20:0] accum_sum =
        {{3{accum_in[17]}}, accum_in} + {result[19], result};
    wire signed [17:0] accum_sat =
        (accum_sum > 21'sd131071)  ? 18'sd131071  :
        (accum_sum < -21'sd131072) ? -18'sd131072 : accum_sum[17:0];

    // A SEND reads a bus's OUTPUT SUM from dmem_local, and at one instruction
    // per cycle the bus it wants may have been written by an instruction
    // still in flight -- the read would silently be stale. Same history,
    // same most-recent-wins rule. The instruction one ahead is in A right
    // now, so its contribution is the combinational accum_sat.
    wire signed [17:0] send_src =
          (a_valid  && a_dest  == r_src) ? accum_sat
        : (wb_valid && wb_addr == r_src) ? wb_value
        : (h1_valid && h1_addr == r_src) ? h1_value
        : (h2_valid && h2_addr == r_src) ? h2_value
        :                                  src_q;

    // LFO waveform on the registered phase (law 1: registered operands).
    // Named wire: a $signed() cast in the port connection crashes yosys's
    // genrtlil signedness assert.
    // bits [24:1]: the extra low bit is the fractional half-step that keeps
    // the LFO frequency unchanged now that passes are twice as frequent
    wire signed [23:0] lfo_phase = $signed(r_istate[24:1]);
    logic signed [17:0] lfo_wave;
    osc_core u_wk_osc (
        .phase_next (lfo_phase),
        .duty       (24'sd0),
        .wave       (r_shape),
        .sample_out (lfo_wave)
    );

    // next state, from X-stage registers only
    wire [1:0]  adsr_stage_prev = x_istate[28:27];
    wire [26:0] adsr_level_prev = x_istate[26:0];
    logic [28:0] istate_next;
    always_comb begin
        if (x_is_lfo) begin
            // free-running phase accumulator in [24:0]
            istate_next = {x_istate[28:25], x_istate[24:0] + {9'b0, x_lfo_rate}};
        end else if (!x_gate) begin
            istate_next = (adsr_level_prev > {6'b0, x_release_step})
                ? {AST_REL, adsr_level_prev - 27'(x_release_step)}
                : {AST_IDLE, 27'd0};
        end else begin
            case (adsr_stage_prev)
                AST_ATT: istate_next =
                    ({1'b0, adsr_level_prev} + 28'(x_attack_step) > 28'h7FFFFFF)
                        ? {AST_DEC, 27'h7FFFFFF}
                        : {AST_ATT, adsr_level_prev + 27'(x_attack_step)};
                AST_DEC: istate_next =
                    (adsr_level_prev > x_sustain_target + 27'(x_decay_step))
                        ? {AST_DEC, adsr_level_prev - 27'(x_decay_step)}
                        : (adsr_level_prev > x_sustain_target)
                              ? {AST_DEC, x_sustain_target}
                              : {AST_DEC, adsr_level_prev};
                default: istate_next = {AST_ATT, adsr_level_prev};
            endcase
        end
    end

    //----------------------------------------------------------------
    // The pipeline.
    //----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_valid <= 1'b0; r_valid <= 1'b0; x_valid <= 1'b0;
            a_valid <= 1'b0; wb_valid <= 1'b0;
            h1_valid <= 1'b0; h2_valid <= 1'b0;
            pc_addr_d <= '0;
            r_pc <= '0; r_opcode <= '0; r_shape <= '0; r_dest <= '0;
            r_src <= '0; r_lfo_rate <= '0; r_rate <= '0; r_depth <= '0;
            r_istate <= '0;
            x_pc <= '0; x_opcode <= '0; x_dest <= '0; x_istate <= '0;
            x_operand <= '0; x_depth <= '0; x_base <= '0; x_gate <= 1'b0;
            x_lfo_rate <= '0; x_attack_step <= '0; x_decay_step <= '0;
            x_release_step <= '0; x_sustain_target <= '0;
            a_dest <= '0; a_base <= '0; a_product <= '0; a_acc_en <= 1'b0;
            wb_addr <= '0; wb_value <= '0;
            h1_addr <= '0; h1_value <= '0; h2_addr <= '0; h2_value <= '0;
        end else begin
            // F -> D
            d_valid   <= pc_active;
            pc_addr_d <= pc_addr;

            // D -> R: the three config words are out of the RAMs this cycle
            r_valid    <= d_valid;
            r_pc       <= pc_addr_d;
            r_opcode   <= cfg_q[3:0];
            r_shape    <= cfg_q[5:4];
            r_dest     <= cfg_q[15:6];
            r_src      <= cfg_q[25:16];
            r_lfo_rate <= cfg_q[31:16];
            r_rate     <= rate_q;
            r_depth    <= depth_q;
            r_istate   <= istate_q;

            // R -> X: gate / source / base are out; decode and choose
            x_valid   <= r_valid && (r_opcode != synth_pkg::OPC_OFF);
            x_pc      <= r_pc;
            x_opcode  <= r_opcode;
            x_dest    <= r_dest;
            x_istate  <= r_istate;
            x_base    <= base_q;
            x_depth   <= $signed(r_depth[17:0]);
            x_gate    <= (gate_q > 18'sd0);
            x_lfo_rate <= r_lfo_rate;
            // Increment is (16 + low4) << high4 in 1/16-LSB units -- one
            // uniform expression, no truncating right shift, so all 256
            // codes are distinct equal-ratio steps of a log2 ladder.
            x_attack_step    <= (21'd16 + 21'(r_rate[3:0]))   << r_rate[7:4];
            x_decay_step     <= (21'd16 + 21'(r_rate[11:8]))  << r_rate[15:12];
            x_sustain_target <= {r_rate[23:16], 19'b0};
            x_release_step   <= (21'd16 + 21'(r_rate[27:24])) << r_rate[31:28];
            x_operand <= r_is_lfo ? lfo_wave
                       : r_is_env ? $signed({2'b0, r_istate[26:11]})
                       :            send_src;

            // X -> A: the multiply, registered operands, alone in its stage
            a_valid   <= x_valid;
            a_acc_en  <= x_acc_en;
            a_dest    <= x_dest;
            a_base    <= x_base;
            a_product <= x_mul_en ? (x_operand * x_depth)
                                  : $signed({{2{x_operand[17]}}, x_operand, 16'd0});

            // A -> W: the saturated sum, and push the forwarding history
            wb_valid <= a_valid && (a_dest != 10'd0);
            wb_addr  <= a_dest;
            wb_value <= accum_sat;
            h1_valid <= wb_valid; h1_addr <= wb_addr; h1_value <= wb_value;
            h2_valid <= h1_valid; h2_addr <= h1_addr; h2_value <= h1_value;
        end
    end

    assign dmem_wdata = wb_value;
    assign dmem_waddr = wb_addr;
    assign dmem_we    = wb_valid;

    // Memory reads. The three imem RAMs share one address, so CFG, RATES and
    // DEPTH all arrive together instead of over three cycles. dmem_gate and
    // dmem_init are the same image read at two different addresses in the
    // same cycle, which is the other thing that used to cost a phase.
    always_ff @(posedge clk) begin
        cfg_q    <= imem_cfg[{bank_active, pc_addr}];
        rate_q   <= imem_rate[{bank_active, pc_addr}];
        depth_q  <= imem_depth[{bank_active, pc_addr}];
        istate_q <= istate[pc_addr];
        gate_q   <= dmem_gate[cfg_q[25:16]];   // watched gate bus
        src_q    <= dmem_local[cfg_q[25:16]];  // SEND source: bus output sum
        base_q   <= dmem_init[cfg_q[15:6]];    // the target's initial value
    end

    always_ff @(posedge clk)
        if (x_valid && x_st_en)
            istate[x_pc] <= istate_next;

    //----------------------------------------------------------------
    // Sink read ports. One BSRAM read port per replica, addressed by
    // the lane pipeline's S1 pointers, registered so the data lands at
    // S2 -- identical timing to when these RAMs were inline.
    //----------------------------------------------------------------
    always_ff @(posedge clk) begin
        rd_pitch_d <= dmem_pitch[{dmem_gen, rd_pitch_a}];
        rd_duty_d  <= dmem_duty[{dmem_gen, rd_duty_a}];
        rd_fc_d    <= dmem_fc[{dmem_gen, rd_fc_a}];
        rd_q_d     <= dmem_q[{dmem_gen, rd_q_a}];
        rd_gl_d    <= dmem_gl[{dmem_gen, rd_gl_a}];
        rd_gr_d    <= dmem_gr[{dmem_gen, rd_gr_a}];
    end

endmodule
`default_nettype wire
