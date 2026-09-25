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

    // SPI bus-base writes (sclk domain). #127: these go to the SHADOW
    // bank and are published by the same slot-512 swap as every other
    // parameter -- the mechanism that already existed for exactly this.
    // The mailbox that used to live here, and the two-take write-through
    // #134 bolted onto it, are both gone: they were a second way of
    // doing what imem and the element param RAMs already did, and the
    // read-during-write they caused is what Thor heard as scratching.
    input  wire         dmem_write_enable,
    input  wire [9:0]   dmem_write_addr,
    input  wire [17:0]  dmem_write_data,

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
    // #127: the LINEAR gain sinks. Addressed LATE, from the element
    // index coming out of the SVF rather than from the S1 pointers,
    // because routing two 18-bit values through svf_tpt's 17 stages
    // would have cost about 600 registers (Thor's call, phase 1).
    input  wire [8:0]   rd_gll_a,
    input  wire [8:0]   rd_glr_a,
    output logic signed [17:0] rd_pitch_d,
    output logic signed [17:0] rd_duty_d,
    output logic signed [17:0] rd_fc_d,
    output logic signed [17:0] rd_q_d,
    output logic signed [17:0] rd_gl_d,
    output logic signed [17:0] rd_gr_d,
    output logic signed [17:0] rd_gll_d,
    output logic signed [17:0] rd_glr_d,

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
    // #127 phase 1: two more sinks, so two more replicas. These carry a
    // LINEAR gain in Q4.14 (unity 0x4000) rather than the octaves the
    // rest of the pool uses -- the first non-logarithmic quantity on the
    // bus. Law 5's Q8.10 does not fit it: ten fractional bits would put
    // a -60 dB envelope tail on a single LSB, and Q4.14 puts it on 16.
    // They are otherwise ordinary replicas, so the ping-pong generation
    // and the SPI mailbox cover them without a special case.
    reg signed [17:0] dmem_gll   [0:2*synth_pkg::DMEM_WORDS-1];
    reg signed [17:0] dmem_glr   [0:2*synth_pkg::DMEM_WORDS-1];
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
        dmem_gll[bi]   = 18'sd0;
        dmem_glr[bi]   = 18'sd0;
    end

    // The BASE register file. Sinks read the replicas; the sequencer
    // reads the base and writes base + contribution into the replicas
    // ("bus = base register + instruction contributions").
    //
    // #127: BANKED, exactly like imem and the element param RAMs --
    // written to bank_shadow on sclk, read from bank_active. A bus no
    // instruction targets is kept in step with its base by the base
    // sweep further down, which is what the mailbox's direct replica
    // write used to do.
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

    // ---- base sweep (#127) -------------------------------------------
    // A bus no instruction targets is never written by the sequencer, so
    // something has to carry its base into the replicas. The mailbox did
    // it as a side effect of committing; that mailbox is gone, so a sweep
    // does it instead, in the slots where the sequencer is idle and the
    // lane has finished.
    //
    // The "produced" map is what stops the sweep clobbering a
    // contribution. The generation flips once per COMPLETE pass -- two
    // samples -- and BOTH halves' instructions write into that one
    // generation. A sweep that straddles a program counter pass would
    // reset a bus the sequencer had already summed, which is the #134
    // bug wearing a different coat.
    // Declared here because the sweep below reads them and iverilog
    // binds declaration-before-use at module scope; both are driven
    // further down, where they belong.
    logic               pc_running;
    logic signed [17:0] dmem_init_readout;

    logic [synth_pkg::DMEM_WORDS-1:0] produced;
    logic [8:0]         sweep_addr;
    logic [8:0]         sweep_addr_d;
    logic               sweep_valid_d;

    // pc_running covers slots 1..390; the lane's reads finish at 273. So
    // !pc_running is 391..767 -- clear of both readers, 377 slots a
    // sample, enough to cover all 512 buses inside one generation.
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)           sweep_addr <= 9'd0;
        else if (!pc_running) sweep_addr <= sweep_addr + 9'd1;

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            sweep_addr_d <= 9'd0; sweep_valid_d <= 1'b0;
        end else begin
            sweep_addr_d  <= sweep_addr;
            // bus 0 is hardwired zero and is never swept
            sweep_valid_d <= !pc_running && !produced[sweep_addr]
                             && (sweep_addr != 9'd0);
        end

    always_ff @(posedge sclk)
        if (dmem_write_enable && (dmem_write_addr != 10'd0)
            && (dmem_write_addr != 10'd1023))
            dmem_init[{bank_shadow, dmem_write_addr[8:0]}] <= $signed(dmem_write_data);

    // Address 1023 is the test-tone control latch (issue #81) -- a
    // control register, not a bus, so it is decoded here rather than
    // taking a slot in the pool.
    always_ff @(posedge sclk)
        if (dmem_write_enable && dmem_write_addr == 10'd1023)
            test_tone_en <= dmem_write_data[0];

    // Replica writes: one physical port, two writers — the sequencer
    // owns its cycle (dmem_we), the mailbox defers around it.
    always_ff @(posedge clk)
        if (dmem_we)            dmem_pitch[{~dmem_gen, dmem_waddr[8:0]}] <= dmem_wdata;
        else if (sweep_valid_d) dmem_pitch[{~dmem_gen, sweep_addr_d}]    <= dmem_init_readout;
    always_ff @(posedge clk)
        if (dmem_we)            dmem_duty[{~dmem_gen, dmem_waddr[8:0]}] <= dmem_wdata;
        else if (sweep_valid_d) dmem_duty[{~dmem_gen, sweep_addr_d}]    <= dmem_init_readout;
    always_ff @(posedge clk)
        if (dmem_we)            dmem_fc[{~dmem_gen, dmem_waddr[8:0]}] <= dmem_wdata;
        else if (sweep_valid_d) dmem_fc[{~dmem_gen, sweep_addr_d}]    <= dmem_init_readout;
    always_ff @(posedge clk)
        if (dmem_we)            dmem_q[{~dmem_gen, dmem_waddr[8:0]}] <= dmem_wdata;
        else if (sweep_valid_d) dmem_q[{~dmem_gen, sweep_addr_d}]    <= dmem_init_readout;
    always_ff @(posedge clk)
        if (dmem_we)            dmem_gl[{~dmem_gen, dmem_waddr[8:0]}] <= dmem_wdata;
        else if (sweep_valid_d) dmem_gl[{~dmem_gen, sweep_addr_d}]    <= dmem_init_readout;
    always_ff @(posedge clk)
        if (dmem_we)            dmem_gr[{~dmem_gen, dmem_waddr[8:0]}] <= dmem_wdata;
        else if (sweep_valid_d) dmem_gr[{~dmem_gen, sweep_addr_d}]    <= dmem_init_readout;
    always_ff @(posedge clk)
        if (dmem_we)            dmem_gll[{~dmem_gen, dmem_waddr[8:0]}] <= dmem_wdata;
        else if (sweep_valid_d) dmem_gll[{~dmem_gen, sweep_addr_d}]    <= dmem_init_readout;
    always_ff @(posedge clk)
        if (dmem_we)            dmem_glr[{~dmem_gen, dmem_waddr[8:0]}] <= dmem_wdata;
        else if (sweep_valid_d) dmem_glr[{~dmem_gen, sweep_addr_d}]    <= dmem_init_readout;
    always_ff @(posedge clk)
        // NOT generational, unlike the replicas: this is the
        // sequencer-facing mirror, written and read inside the same pass
        // by SEND, so it is a flat file addressed by the raw address. I
        // gave it generation indexing when the sweep went in and the
        // read stayed flat -- every SEND then read the wrong half.
        if (dmem_we)            dmem_local[dmem_waddr] <= dmem_wdata;
        else if (sweep_valid_d) dmem_local[{1'b0, sweep_addr_d}] <= dmem_init_readout;

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

    // RC envelope (#127 phase 2). The level is a LINEAR AMPLITUDE in
    // UQ12.14 across [25:0]: full scale is 0x400000, which is the
    // linear gain bus's Q4.14 unity (0x4000) carrying eight extra
    // fractional bits, so that a slow step does not truncate away.
    // Every segment is the same recurrence, y += (target - y) * k, and
    // the stage chooses nothing but the target and the rate. Sustain
    // is the only straight line in the envelope, and it is straight
    // because it is a FIXED POINT of that recurrence rather than a
    // special case (Thor, #127).
    localparam [25:0] ENV_FULL = 26'h400000;
    // Attack charges toward 1.3x full scale and the comparator ends it
    // at full scale -- the CEM3310 / SSM2056 trick. What you hear is
    // then the first 77% of an RC charge, which is convex, instead of
    // the tail, which flattens into a soft attack nobody wants.
    localparam [25:0] ENV_OVER = 26'h533333;   // 1.3 * ENV_FULL
    // k = (16 + low4) >> (RC_SHIFT_BIAS + 15 - high4): the SAME 5-bit
    // mantissa and barrel shift the linear rates already used, mirrored
    // from an increment into a fraction. 16 codes per octave over 16
    // octaves = 256 distinct equal-ratio rates with NO TABLE, which is
    // the whole point (Thor: no more LUTs for ADSR).
    //
    // The high nibble is SUBTRACTED because it used to scale an
    // increment and now scales a fraction; keeping it as a plain shift
    // would silently invert every rate byte the firmware already sends.
    // Bias 10 then puts the fastest attack near 1 ms and the slowest
    // release near 44 s, which brackets the ladder it replaces.
    localparam int    RC_SHIFT_BIAS = 10;

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

    // control: 3-slot stride via a small counter, armed at sample_tick.
    // (It said "slot 299" until #127; #134 moved the arming and the
    // comment did not follow, which is what made me mis-measure the
    // idle window twice.)
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
        if (!rst_n)                      dmem_gen <= 1'b0;
        else if (sample_tick && pc_half) dmem_gen <= ~dmem_gen;

    // Set as the sequencer writes, cleared when the generation flips,
    // so it means exactly "written by the sequencer into the
    // generation now being filled".
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)                      produced <= '0;
        else if (sample_tick && pc_half) produced <= '0;
        else if (dmem_we)                produced[dmem_waddr[8:0]] <= 1'b1;
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
    assign pc_running = pc_active || (drain_cnt != 2'd0);
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

    // P2 decode wires. The stage picks the target and which rate byte
    // to read; everything else about the segment is identical.
    // RATES word is the universal A, D, S, R: [7:0] attack rate,
    // [15:8] decay rate, [23:16] SUSTAIN LEVEL, [31:24] release rate.
    // Latched from CFG[26] at P1, so it is declared ahead of the decode
    // that reads it -- iverilog binds declaration-before-use here.
    logic       adsr_sus_log;
    wire        adsr_gate_now = (dmem_init_readout > 18'sd0);
    // Gate high out of IDLE or RELEASE restarts the attack from
    // WHEREVER THE LEVEL IS, which is what a legato retrigger does on
    // the hardware -- no reset to zero, so no click.
    wire [1:0]  adsr_stage_sel_w = !adsr_gate_now ? AST_REL
                                 : (istate_prev[27:26] == AST_DEC) ? AST_DEC
                                 : AST_ATT;
    wire [7:0]  adsr_nib_w = !adsr_gate_now         ? imem_readout[31:24]
                           : (adsr_stage_sel_w == AST_ATT) ? imem_readout[7:0]
                                                           : imem_readout[15:8];
    // SUSTAIN, decoded two ways, because the same generator feeds two
    // kinds of destination and the log-ness of an analog envelope never
    // lived in the pot -- it lived in what the CV was plugged into.
    //
    //   SUS_LOG = 0   the CUTOFF bus is already log2/octave, so it IS
    //                 the V/oct input: send the byte linearly
    //   SUS_LOG = 1   the linear gain bus is AMPLITUDE, the one place
    //                 with no analog counterpart to the exponential
    //                 VCA, so the decode has to go here
    //
    // Larger = louder in both (Thor). The log form is the mantissa and
    // barrel shift a third time, so no table: about 96 dB of range,
    // 0xFF landing 3% under full scale.
    wire [25:0] adsr_sus_lin_v = {4'b0, imem_readout[23:16], 14'b0};
    wire [25:0] adsr_sus_log_v = (26'd16 + 26'(imem_readout[19:16])) << 17
                                 >> (4'd15 - imem_readout[23:20]);
    wire [25:0] adsr_target_w = !adsr_gate_now ? 26'd0
                              : (adsr_stage_sel_w == AST_ATT) ? ENV_OVER
                              : adsr_sus_log ? adsr_sus_log_v
                                             : adsr_sus_lin_v;

    // Rate decode + gate, REGISTERED at P2 (each cone is one RAM
    // output through shifts or a compare — short); the state step
    // then runs at P3 entirely from registers. This split exists
    // because the un-split version made the RAM-output→state-write
    // cone the critical path (76 MHz — 3.5% margin, on a timing
    // model proven optimistic five times).
    logic        adsr_gate;
    logic [4:0]  adsr_mant;        // 16..31, the rate mantissa
    logic [4:0]  adsr_shift;       // high nibble + RC_SHIFT_BIAS
    logic signed [26:0] adsr_delta;  // target - level, signed
    logic [1:0]  adsr_stage_sel;   // the stage this step belongs to

    wire [1:0]  adsr_stage_prev  = istate_prev[27:26];
    wire [25:0] adsr_level_prev  = istate_prev[25:0];

    // ---- the RC step, spread over three phases ------------------------
    // subtract -> multiply -> shift+add, and the silicon rule says the
    // multiply stands alone, so the result lands one phase after the
    // stride ends. The state write is therefore DELAYED BY ONE ENTRY,
    // exactly as the bus write already is (the #97 fix). An instruction
    // is visited once per pass, 128 entries apart, so its own delayed
    // write can never race its own read -- and the stride stays at 3,
    // which is what lets #138 stay a cherry rather than a prerequisite.
    logic signed [31:0] rc_product;   // delta * mantissa (P3 -> P1')
    logic [4:0]  rc_shift_d;
    logic [1:0]  rc_stage_d;
    logic [25:0] rc_level_d;
    logic        rc_gate_d;
    logic        stw_valid, stw_is_lfo;
    logic [7:0]  stw_addr;
    logic [27:0] stw_lfo_next;

    // The shifted step. rc_product's sign IS delta's sign, because the
    // mantissa is always positive.
    wire signed [31:0] rc_step_w = rc_product >>> rc_shift_d;
    // Fixed-point RC STALLS: once the step truncates to zero the level
    // freezes short of its target, and on release that is a DC tail and
    // a voice that never frees -- which would be heard as a stuck note,
    // not as an envelope bug. One LSB of creep bounds the arrival, and
    // 1 LSB of 26 is far below anything audible.
    wire signed [26:0] rc_creep = rc_product[31] ? -27'sd1 : 27'sd1;
    wire signed [26:0] rc_inc   = (rc_step_w == 32'sd0 && rc_product != 32'sd0)
                                ? rc_creep : rc_step_w[26:0];
    wire signed [27:0] rc_y     = $signed({2'b0, rc_level_d}) + 28'(rc_inc);

    logic [27:0] adsr_state_next;
    always_comb begin
        if (!rc_gate_d)
            // release: the target is zero, and IDLE is latched on arrival
            adsr_state_next = (rc_y <= 28'sd0) ? {AST_IDLE, 26'd0}
                                               : {AST_REL, rc_y[25:0]};
        else if (rc_stage_d == AST_ATT)
            // attack: the comparator, not the target, ends the segment
            adsr_state_next = (rc_y >= $signed({2'b0, ENV_FULL}))
                            ? {AST_DEC, ENV_FULL} : {AST_ATT, rc_y[25:0]};
        else
            // decay: it ARRIVES at sustain. An RC segment cannot
            // overshoot its target, so the three-way compare the linear
            // ramp needed here is simply gone.
            adsr_state_next = {AST_DEC, rc_y[25:0]};
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
            adsr_sus_log <= 1'b0;
            adsr_mant <= '0; adsr_shift <= '0; adsr_delta <= '0;
            adsr_stage_sel <= AST_IDLE;
            rc_product <= '0; rc_shift_d <= '0; rc_stage_d <= AST_IDLE;
            rc_level_d <= '0; rc_gate_d <= 1'b0;
            stw_valid <= 1'b0; stw_is_lfo <= 1'b0; stw_addr <= '0;
            stw_lfo_next <= '0;
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
                // CFG[26] = SUS_LOG. An ADSR uses CFG[25:16] as its gate
                // bus and nothing above it, so this bit is free.
                adsr_sus_log <= imem_readout[26];
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
                adsr_gate <= adsr_gate_now;
                adsr_stage_sel <= adsr_stage_sel_w;
                adsr_mant  <= 5'd16 + {1'b0, adsr_nib_w[3:0]};
                // The exponent is INVERTED against the old ladder on
                // purpose. There, the high nibble was a LEFT shift on an
                // increment, so bigger meant faster; here it scales a
                // FRACTION, so the same byte has to be subtracted to keep
                // its meaning. Without this, every rate the firmware
                // already sends would come out at the opposite end of the
                // ladder -- the bench's "fast sim rates" would be the
                // slowest the machine can do.
                adsr_shift <= 5'(RC_SHIFT_BIAS) + 5'(4'd15 - adsr_nib_w[7:4]);
                adsr_delta <= $signed({1'b0, adsr_target_w})
                            - $signed({1'b0, adsr_level_prev});
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
                // The ADSR emits a LINEAR AMPLITUDE now, not a log gain
                // code: [24:8] of the UQ12.14 level is exactly Q4.14
                // with unity 0x4000, the linear gain bus's format. The
                // curve is in the recurrence, so att_lut is out of the
                // envelope's path entirely (#127).
                operand   <= (opcode_a == 4'd1) ? lfo_wave
                                    : (opcode_a == 4'd3) ? bus_sum_readout
                                            : $signed({1'b0, istate_prev[24:8]});
                wb_valid  <= 1'b0;              // P5 write just happened
            end else begin
                // end of P3 (phase == 0): the instruction multiply —
                // registered operands (operand, and imem_readout = DEPTH);
                // state writeback happens here too (see below)
                instr_valid_c   <= instr_valid_b;
                dest_addr_c <= dest_addr_b;
                coeff_product     <= operand * $signed(imem_readout[17:0]);
                // The RC multiply -- by a 5-bit mantissa, alone in its
                // phase, beside the DEPTH multiply and independent of it.
                rc_product  <= adsr_delta * $signed({1'b0, adsr_mant});
                rc_shift_d  <= adsr_shift;
                rc_stage_d  <= adsr_stage_sel;
                rc_level_d  <= adsr_level_prev;
                rc_gate_d   <= adsr_gate;
                // Arm the state write for the NEXT entry's P1.
                stw_valid   <= instr_valid_a && (opcode_a == 4'd1 || opcode_a == 4'd2);
                stw_is_lfo  <= (opcode_a == 4'd1);
                stw_addr    <= pc_a;
                stw_lfo_next <= {istate_prev[27:24],
                                 istate_prev[23:0] + {8'b0, lfo_rate_a}};
                instr_valid_b   <= 1'b0;
                instr_valid_a   <= 1'b0;
            end
        end
    end

    assign dmem_wdata = wb_value;
    assign dmem_waddr = wb_addr;
    assign dmem_we  = wb_valid && (phase == 2'd2);

    wire [9:0] init_rd_a = (phase == 2'd1) ? imem_readout[25:16] : dest_addr_b;

    // sequencer memory reads — sync-only, one register per RAM, address
    // muxed by phase: imem serves CFG (P0) / RATES (P1) /
    // DEPTH (P2); dmem_init serves the gate bus (P1, address from the
    // CFG word just read) / the target base (P3).
    always_ff @(posedge clk) begin
        imem_readout  <= imem[{bank_active, pc_addr, phase}];
        istate_readout    <= istate[pc_addr];
        // The sequencer's base/gate read and the sweep's read share one
        // port. They never want it at the same time: the sweep only runs
        // when the sequencer is idle.
        dmem_init_readout <= pc_running
                           ? dmem_init[{bank_active, init_rd_a[8:0]}]
                           : dmem_init[{bank_active, sweep_addr}];
        // SEND source read (#92/#98): the OUTPUT SUM of CFG[25:16] —
        // read in parallel with dmem_init (own RAM, own register);
        // P2 selects by type. Only meaningful at P1.
        bus_sum_readout <= dmem_local[imem_readout[25:16]];
    end
    // One write port, one phase, both generators: the LFO's accumulator
    // rides the same one-entry delay as the RC step so that the state
    // RAM never needs a second write port.
    always_ff @(posedge clk)
        if ((phase == 2'd1) && stw_valid)
            istate[stw_addr] <= stw_is_lfo ? stw_lfo_next : adsr_state_next;
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
        // Late reads, but still inside the lane's read window, so the
        // "no straddle" invariant (tb_prog_pingpong) has to cover these
        // two as well -- a generation flip between the S1 reads and
        // these would mix halves within one element. Asserted, not
        // assumed.
        rd_gll_d   <= dmem_gll[{dmem_gen, rd_gll_a}];
        rd_glr_d   <= dmem_glr[{dmem_gen, rd_glr_a}];
    end

endmodule
`default_nettype wire
