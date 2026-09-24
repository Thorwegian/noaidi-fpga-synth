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
    integer bbi;
    initial for (bbi = 0; bbi < 2*synth_pkg::DMEM_WORDS; bbi = bbi + 1)
        dmem_init[bbi] = 18'sd0;

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
    logic dmem_gen;   // process below, with pc_half

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
    // Program counter (B4/B5, bus_architecture.md) — the idle-slot
    // table executor. 128 entries × 3 config words (stride 4 in the
    // RAM), 3 slots per entry, span 300..~690. Law 1: the ONE
    // instruction multiply sits alone in its own stage with registered
    // operands. Law 3: entries execute in table order, once per
    // sample. A instruction's OUTPUT uses the PREVIOUS sample's state —
    // the one-sample lag is inaudible at control rates and it keeps
    // the sine's internal multiply and the instruction multiply fed by
    // registers only.
    //
    // Per-entry phases (overlapped across entries):
    //   P0: read CFG + state
    //   P1: latch cfg/state; read RATES; read gate bus (dmem_init)
    //   P2: REGISTER rate decode + gate + source (each a short
    //       RAM-output cone); read DEPTH
    //   P3: state step from registers (adds/compares) + writeback;
    //       source × depth (DSP, registered operands — a parallel,
    //       independent path); read target base (dmem_init — port
    //       shared with P1 by phase mux)
    //   P4: REGISTER value = base + (product >>> 16), saturated
    //   P5: write replicas (the RAM→add→clamp→RAM chain carries a
    //       register in the middle — the 76 MHz critical path fix)
    //
    // ADSR state word: [23:22] stage (0 idle, 1 attack, 2 decay/
    // sustain, 3 release), [21:0] level. Gate is LEVEL-sensitive on
    // the watched bus (> 0 = held): note-on/off is one live bus write.
    //----------------------------------------------------------------
    localparam [1:0] AST_IDLE = 2'd0, AST_ATT = 2'd1,
                     AST_DEC  = 2'd2, AST_REL = 2'd3;

    reg [35:0] imem [0:8*synth_pkg::NUM_INSTR-1]; // {bank,entry[7:0],word[1:0]}
    // State word: LFO uses [23:0] as its phase; ADSR uses [27:26] as
    // the stage and [25:0] as the level in UQ22.4 — FOUR FRACTIONAL
    // BITS, so rate increments are in 1/16-LSB units and the 8-bit
    // log2 rate byte decodes as ONE uniform expression with no
    // truncation anywhere: all 256 codes are distinct equal-ratio
    // steps (Thor's perceptual-linearity rule; a MIDI CC maps as
    // cc << 1). The fractional bits ARE the "binary point moved four
    // left" — in the accumulator, where it belongs.
    reg [27:0] istate [0:synth_pkg::NUM_INSTR-1];
    integer wi;
    initial begin
        for (wi = 0; wi < 8*synth_pkg::NUM_INSTR; wi = wi + 1)
            imem[wi] = 36'd0;                  // type 0 = off
        for (wi = 0; wi < synth_pkg::NUM_INSTR; wi = wi + 1)
            istate[wi] = 28'd0;
    end

    always_ff @(posedge sclk)
        if (imem_write_enable) imem[{bank_shadow, imem_write_addr}] <= {4'b0, imem_write_data};

    // control: 3-slot stride via a small counter, armed at slot 299.
    // HALF-RATE (#100): each sample walks 128 entries — ONE HALF of
    // the 256-entry table, halves alternating by pc_half — so a
    // source updates at 48 kHz effective (zipper at 24 kHz, under
    // the master tilt; Thor 2026-09-11). Chains must live within a
    // half (allocator rule); cross-half reads see the other half's
    // previous pass.
    logic [1:0] phase;
    logic [7:0] pc;
    logic       pc_half;

    // #134: the generation flips once per COMPLETE sequencer pass, not once
    // per sample. The sequencer is half-rate (#100) -- one half of the
    // instruction table per sample -- so a instruction refreshes its bus every
    // OTHER sample. Flipping every sample would publish a generation the
    // sequencer had only half written, which reads as halved modulation
    // depth and a stale link in any chain. pc_half marks the
    // two-sample cycle, so the swap rides it.
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)                          dmem_gen <= 1'b0;
        else if (sample_tick && pc_half) dmem_gen <= ~dmem_gen;
    wire pc_active = (pc < 8'(synth_pkg::INSTR_PER_PASS));
    // #97 fix: the bus write is pipeline-delayed by one entry — entry N's
    // write fires during entry N+1's P5. Without a drain the step machine
    // freezes the instant pc hits INSTR_PER_PASS, so the LAST
    // real entry's write (index 127 in half A = PROD_FANOUT(31), voice
    // 31's cutoff send) never lands and that voice reads a stale/low
    // cutoff bus. Keep advancing while draining so the trailing write
    // completes. The drain entries carry instruction_valid=0 (pc_active
    // gates the reads), so they inject nothing; they only flush the last
    // write and clear wb_prev_valid, so no chain leaks across halves.
    // A registered pc_draining keeps the pc->RAM-address
    // path off the extended compare (timing).
    localparam int PIPE_DRAIN = 2;
    logic [1:0] drain_cnt;
    wire pc_running = pc_active || (drain_cnt != 2'd0);
    wire [7:0] pc_addr = {pc_half, pc[6:0]};
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= 2'd0; pc <= 8'hFF; pc_half <= 1'b0;
            drain_cnt <= 2'd0;
        end else if (sample_tick) begin
            phase <= 2'd0; pc <= 8'd0;
            pc_half <= ~pc_half;
            drain_cnt <= 2'(PIPE_DRAIN);
        end else if (pc_running) begin
            if (phase == 2'd2) begin
                phase <= 2'd0;
                pc <= pc + 8'd1;
                if (!pc_active && drain_cnt != 2'd0)
                    drain_cnt <= drain_cnt - 2'd1;
            end else
                phase <= phase + 2'd1;
        end
    end
    wire pc_entry_start = pc_active && (phase == 2'd0);

    // Sequential read registers: imem serves CFG/RATES/DEPTH on
    // consecutive cycles through ONE register (address muxed by
    // phase); dmem_init serves the gate read (P1) and the target-base
    // read (P3) through one register the same way.
    logic [35:0] imem_readout;
    logic [27:0] istate_readout;
    logic signed [17:0] dmem_init_readout;
    logic signed [17:0] bus_sum_readout;   // send-source read (#92/#98)
    logic        pc_read_valid; // a P0 read was issued last cycle

    // A stage — latched at the end of P1, stable for 3 cycles
    logic        instr_valid_a;
    logic [7:0]  pc_a;   // {half, entry[6:0]} (#100)
    logic [3:0]  opcode_a;
    logic [1:0]  lfo_shape_a;
    logic [9:0]  dest_addr_a;
    logic [15:0] lfo_rate_a;
    logic [27:0] istate_prev;
    // B stage — latched at the end of P2
    logic        instr_valid_b;
    logic [9:0]  dest_addr_b;
    logic signed [17:0] operand;
    // C stage — latched at the end of P3
    logic        instr_valid_c;
    logic [9:0]  dest_addr_c;
    logic signed [35:0] coeff_product;
    // E stage — the saturated sum, latched at the end of P4
    logic        wb_valid;
    logic [9:0]  wb_addr;
    logic signed [17:0] wb_value;

    // LFO waveform on the OLD phase (registered istate_prev → rule-clean).
    // Named intermediate wire: a $signed() cast directly in the port
    // connection crashes yosys's genrtlil signedness assert.
    wire signed [23:0] lfo_phase = $signed(istate_prev[23:0]);
    logic signed [17:0] lfo_wave;
    osc_core u_wk_osc (
        .phase_next (lfo_phase), // LFO phase is the accumulator (#128)
        .duty       (24'sd0),
        .wave       (lfo_shape_a),
        .sample_out (lfo_wave)
    );

    // Rate decode + gate, REGISTERED at P2 (each cone is one RAM
    // output through shifts or a compare — short); the state step
    // then runs at P3 entirely from registers. This split exists
    // because the un-split version made the RAM-output→state-write
    // cone the critical path (76 MHz — 3.5% margin, on a timing
    // model proven optimistic five times).
    logic        adsr_gate;
    logic [20:0] adsr_attack_step, adsr_decay_step, adsr_release_step;   // 1/16-LSB units
    logic [25:0] adsr_sustain_target;

    // next-state, computed at P3 from registered inputs only.
    // ADSR level is UQ22.4 (26 bits).
    wire [1:0]  adsr_stage_prev  = istate_prev[27:26];
    wire [25:0] adsr_level_prev  = istate_prev[25:0];
    logic [27:0] istate_next;
    always_comb begin
        if (opcode_a == 4'd1) begin
            // LFO: free-running phase accumulator in [23:0]
            istate_next = {istate_prev[27:24], istate_prev[23:0] + {8'b0, lfo_rate_a}};
        end else if (!adsr_gate) begin
            // ADSR, gate low: release toward zero
            istate_next = (adsr_level_prev > {5'b0, adsr_release_step})
                ? {AST_REL, adsr_level_prev - 26'(adsr_release_step)}
                : {AST_IDLE, 26'd0};
        end else begin
            case (adsr_stage_prev)
                AST_ATT: istate_next =
                    ({1'b0, adsr_level_prev} + 27'(adsr_attack_step) > 27'h3FFFFFF)
                        ? {AST_DEC, 26'h3FFFFFF}
                        : {AST_ATT, adsr_level_prev + 26'(adsr_attack_step)};
                AST_DEC: istate_next =
                    (adsr_level_prev > adsr_sustain_target + 26'(adsr_decay_step))
                        ? {AST_DEC, adsr_level_prev - 26'(adsr_decay_step)}
                        : (adsr_level_prev > adsr_sustain_target) ? {AST_DEC, adsr_sustain_target}
                                             : {AST_DEC, adsr_level_prev};
                default: istate_next = {AST_ATT, adsr_level_prev};  // idle/release
            endcase
        end
    end

    // P4 (phase == 1) combinational: value = addend + contribution,
    // saturating — REGISTERED into sequencer_write_* at the end of P4, written to
    // the replicas at P5 (phase == 2). The RAM-output → add → clamp →
    // RAM-write chain carries a register in the middle (the 76 MHz
    // critical-path fix). Declared before the stage block below
    // (iverilog binds declaration-before-use at module scope).
    //
    // BUS SUMMING (issue #84, law 1 made real): buses are summing
    // nodes — exactly like mixing-console buses, never
    // self-referential (Thor, #98) — so summing is the DEFAULT, no
    // flags. At this moment the sequencer_write_* registers still hold
    // the PREVIOUS entry's result; if this entry targets the same
    // TARGET bus as that previous entry, accumulate onto the running
    // total instead of re-reading the firmware base. Multiple sources
    // SHARING A TARGET BUS therefore sum automatically when allocated
    // in consecutive slots, to any chain length (each link sees the
    // running total — the cumulative sum, nothing more). The
    // allocator's rule (bus_architecture.md): group sources that
    // share a target bus adjacently; scattered ones keep
    // last-write-wins.
    wire signed [19:0] result = coeff_product[35:16];
    // wb_valid is cleared after the P5 RAM write, so the
    // chain test uses its own uncleaned copy (bus/value persist).
    logic wb_prev_valid;
    wire chain_prev = wb_prev_valid
                      && (wb_addr == dest_addr_c);
    wire signed [17:0] accum_in =
        chain_prev ? wb_value : dmem_init_readout;
    wire signed [20:0] accum_sum =
        {{3{accum_in[17]}}, accum_in} + {result[19], result};
    wire signed [17:0] accum_sat =
        (accum_sum > 21'sd131071)  ? 18'sd131071  :
        (accum_sum < -21'sd131072) ? -18'sd131072 : accum_sum[17:0];

    // Phase-guarded stage latches: each stage latches only at its own
    // phase edge and stays stable for the entry's three cycles.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_read_valid <= 1'b0;
            instr_valid_a <= 1'b0; instr_valid_b <= 1'b0; instr_valid_c <= 1'b0; wb_valid <= 1'b0;
            wb_prev_valid <= 1'b0;
            pc_a <= '0; opcode_a <= '0; lfo_shape_a <= '0;
            dest_addr_a <= '0; lfo_rate_a <= '0; istate_prev <= '0;
            dest_addr_b <= '0; operand <= '0;
            dest_addr_c <= '0; coeff_product <= '0;
            wb_addr <= '0; wb_value <= '0;
            adsr_gate <= 1'b0;
            adsr_attack_step <= '0; adsr_decay_step <= '0; adsr_release_step <= '0; adsr_sustain_target <= '0;
        end else begin
            pc_read_valid <= pc_entry_start;

            if (phase == 2'd1) begin
                // end of P1: latch config (imem_readout = CFG) + state
                instr_valid_a     <= pc_read_valid;
                pc_a     <= pc_addr;
                opcode_a  <= imem_readout[3:0];
                lfo_shape_a <= imem_readout[5:4];
                dest_addr_a   <= imem_readout[15:6];
                lfo_rate_a  <= imem_readout[31:16];
                istate_prev      <= istate_readout;
                // ...and register the previous entry's saturated sum
                // (write happens next cycle, at P5)
                wb_valid   <= instr_valid_c && (dest_addr_c != 10'd0);
                wb_prev_valid    <= instr_valid_c && (dest_addr_c != 10'd0);
                wb_addr <= dest_addr_c;
                wb_value <= accum_sat;
                instr_valid_c    <= 1'b0;
            end else if (phase == 2'd2) begin
                // end of P2: register the rate decode + gate (short
                // RAM-output cones) and the source from OLD state
                // RATES field order is the universal A, D, S, R —
                // bytes 0,1 = attack/decay rates, byte 2 = SUSTAIN
                // level, byte 3 = release rate (Thor: S is a level
                // and sits third by convention). One sustain LSB
                // = 0.375 dB below peak at the 16-octave amp depth.
                // Rate decode: increment = (16 + low4) << high4 in
                // 1/16-LSB units — the level's four fractional bits
                // carry the four-octave down-bias (decay only
                // traverses peak→sustain, so unbiased rates made
                // every decay fast). ONE uniform expression, no
                // truncating right-shift: all 256 codes are distinct
                // equal-ratio steps of a log2 ladder (Thor's
                // perceptual-linearity rule; a MIDI CC maps as
                // cc << 1). Slowest full-range time ~44 s, fastest
                // ~0.7 ms.
                adsr_gate <= (dmem_init_readout > 18'sd0);
                adsr_attack_step <= (21'd16 + 21'(imem_readout[3:0]))
                               << imem_readout[7:4];
                adsr_decay_step <= (21'd16 + 21'(imem_readout[11:8]))
                               << imem_readout[15:12];
                adsr_sustain_target  <= {imem_readout[23:16], 18'b0};
                adsr_release_step <= (21'd16 + 21'(imem_readout[27:24]))
                               << imem_readout[31:28];
                // Source types: 1 = LFO, 2 = ADSR (generators), 3 =
                // SEND (the fabric's processor — #44/#98). A send is
                // STATELESS: CFG[25:16] names the source bus (the
                // field the ADSR uses for its GATE input), the value
                // read is the bus's OUTPUT SUM (dmem_local, #92 —
                // firmware base + all contributions written so far;
                // sources ordered before their sends propagate
                // same-sample), multiplied by DEPTH like any source
                // (0x10000 = unity, sign = polarity) and chain-added
                // to the target.
                instr_valid_b   <= instr_valid_a && (opcode_a == 4'd1 || opcode_a == 4'd2
                                                           || opcode_a == 4'd3);
                dest_addr_b <= dest_addr_a;
                operand   <= (opcode_a == 4'd1) ? lfo_wave
                                    : (opcode_a == 4'd3) ? bus_sum_readout
                                            : $signed({2'b0, istate_prev[25:10]});
                wb_valid  <= 1'b0;              // P5 write just happened
            end else begin
                // end of P3 (phase == 0): the instruction multiply —
                // registered operands (operand, and imem_readout = DEPTH);
                // state writeback happens here too (see below)
                instr_valid_c   <= instr_valid_b;
                dest_addr_c <= dest_addr_b;
                coeff_product     <= operand * $signed(imem_readout[17:0]);
                instr_valid_b   <= 1'b0;
                instr_valid_a   <= 1'b0;
            end
        end
    end

    assign dmem_wdata = wb_value;
    assign dmem_waddr = wb_addr;
    assign dmem_we  = wb_valid && (phase == 2'd2);

    // sequencer memory reads — sync-only, one register per RAM, address
    // muxed by phase: imem serves CFG (P0) / RATES (P1) /
    // DEPTH (P2); dmem_init serves the gate bus (P1, address from the
    // CFG word just read) / the target base (P3).
    always_ff @(posedge clk) begin
        imem_readout  <= imem[{bank_active, pc_addr, phase}];
        istate_readout    <= istate[pc_addr];
        dmem_init_readout <= dmem_init[(phase == 2'd1) ? imem_readout[25:16]
                                              : dest_addr_b];
        // SEND source read (#92/#98): the OUTPUT SUM of CFG[25:16] —
        // read in parallel with dmem_init (own RAM, own register);
        // P2 selects by type. Only meaningful at P1.
        bus_sum_readout <= dmem_local[imem_readout[25:16]];
    end
    always_ff @(posedge clk)
        if ((phase == 2'd0) && instr_valid_a
            && (opcode_a == 4'd1 || opcode_a == 4'd2))
            istate[pc_a] <= istate_next;                      // P3
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
