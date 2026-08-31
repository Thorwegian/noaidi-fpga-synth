//--------------------------------------------------------------------
// element_pipeline.sv — 256-element SCMO pipeline (the drum's lanes)
//
// One element enters a lane every sysclk cycle for 256 cycles of
// each sample period (drum slot 0..255).  Every cycle, every stage
// processes a different element: stage Sk at drum slot t holds the
// element that entered at slot t-k.  The pipeline occupies
// 256 + 16 - 1 = 271 contiguous slots (~35% of the 768-slot drum
// rotation).
//
// Stage map:
//   S1  state/param RAM read data available (address issued at S0)
//   S2  issue phase-delta + SVF-K LUT reads
//   S3  LUT data → delta, K, q1; phase_next; oscillator waveform
//   S3B register the barrel-shifted K / osc sample / phase_next
//   S4  SVF1 A:  m1 = K*ic1eq1,  m2 = q1*ic1eq1     (DSP)
//   S5  SVF1 B1: lp1/hp1 adder tree
//   S5B SVF1 B2: m3 = K*hp1 on registered hp1        (DSP)
//   S6  SVF1 C:  bp1, new states, filter-1 output
//   S7  SVF2 A:  m4 = K*ic1eq2,  m5 = q1*ic1eq2     (DSP)
//   S8  SVF2 B1: lp2/hp2 adder tree
//   S8B SVF2 B2: m6 = K*hp2 on registered hp2        (DSP)
//   S9  SVF2 C:  bp2, new states, filter-2 output, element output
//   S9B attenuation decode: lin gains via LUT + barrel shift
//   S10 attenuation multiply on registered operands      (DSP)
//   S11 mix accumulate + state writeback
//
// S3B/S5B/S8B/S9B exist because chaining adder trees or LUT+barrel-
// shift decodes into a DSP multiply in one cycle violated setup on
// real silicon at 98.304 MHz (audible corruption, clean at half
// clock) — paths nextpnr's approximate timing model passes. Rule: a
// stage is adds/decode-only or multiply-only, never both chained.
// S3B was the last of the class (2026-08-30): once per-element fc gave
// consecutive lanes different K shift amounts, chords screamed in the
// left channel — the glitched lane after a group boundary is a
// left-panned element. No known residual of this class remains.
//
// Number formats (design doc):
//   phase      UQ0.24  (24-bit)
//   audio      Q2.16   (18-bit)
//   SVF states Q8.28   (36-bit)
//   pitch/fc   UQ4.10  (14-bit)
//   gain       UQ4.4   (8-bit, log: 6 dB int steps + 0.375 dB frac)
//
// State RAM is semi dual-port: read address is issued with the element
// entering at S0, writeback happens 15 cycles later — the read
// and write addresses can never collide.
//--------------------------------------------------------------------
`default_nettype none
module element_pipeline #(
    parameter int NUM_ELEMENTS = synth_pkg::NUM_ELEMENTS,
    // Boot parameter images. Synthesis uses the tree's generated
    // images; testbenches override with rtl/tb/ref_boot_* (committed
    // fixtures) so bench expectations never depend on bench-local
    // experiments in scripts/gen_boot_image.py.
    parameter P0_HEX = "element/boot_p0.hex",
    parameter P1_HEX = "element/boot_p1.hex",
    parameter P2_HEX = "element/boot_p2.hex",
    parameter P3_HEX = "element/boot_p3.hex"
) (
    input  logic           clk,
    input  logic           rst_n,

    input  logic [9:0]     slot,
    input  logic           lane_enter,
    input  logic           sample_tick,

    // Per-element parameter writes from the SPI control plane.
    // sclk-domain write port on the param RAMs; the pipeline reads on
    // clk (sysclk) — the dual-clock BSRAM is the CDC (design doc).
    //
    // PING-PONG (memory map decision 7): the banks are doubled —
    // reads always hit the ACTIVE half, writes always the SHADOW half,
    // so a read and a write can never collide on one address (the
    // click-on-sweep bug). swap_req (an sclk-domain toggle from
    // CTRL@0x0002) flips the active half at drum slot 512: the
    // pipeline is drained there (span ends ~271), so every sample's
    // 256 elements read one consistent bank generation.
    input  logic           sclk,
    input  logic           pe_we,
    input  logic [2:0]     pe_bank,     // 0..6 = p0..p3, GATE, PTRS0, PTRS1

    // Bus-write mailbox from spi_bus (sclk-domain toggle + payload).
    // Synced here and committed to bus RAM only in an idle drum slot,
    // so a commit never collides with a lane's bus read.
    input  logic [9:0]     bw_addr,
    input  logic [17:0]    bw_data,
    input  logic           bw_req,

    // Producer table writes (sclk domain, banked — wiring per law 4)
    input  logic           pw_we,
    input  logic [7:0]     pw_addr,     // {entry[6:0], word[0]}
    input  logic [31:0]    pw_data,
    input  logic [7:0]     pe_elem,
    input  logic [31:0]    pe_wdata,
    input  logic           swap_req,    // sclk-domain toggle

    output logic signed [23:0] mix_left,    // Q0.24, updated at sample_tick
    output logic signed [23:0] mix_right
);

    localparam int VW = $clog2(NUM_ELEMENTS);   // element index width

    //----------------------------------------------------------------
    // LUT ROMs (combinational reads)
    //----------------------------------------------------------------
    reg [23:0] phase_lut [0:1023];     // osc phase delta, one octave
    reg [15:0] k_lut     [0:1023];     // SVF K mantissa, one octave
    reg [16:0] att_lut   [0:15];       // log-gain fractional part

    initial begin
        $readmemh("element/phase_lut.hex", phase_lut);
        $readmemh("element/svf_k_lut.hex", k_lut);
        $readmemh("element/att_lut.hex", att_lut);
    end

    //----------------------------------------------------------------
    // Per-element internal state RAM — semi dual-port
    // read address: entering element (S0), write: 15 cycles later
    //----------------------------------------------------------------
    reg signed [23:0] phase_ram  [0:NUM_ELEMENTS-1];
    reg signed [35:0] ic1eq1_ram [0:NUM_ELEMENTS-1];
    reg signed [35:0] ic2eq1_ram [0:NUM_ELEMENTS-1];
    reg signed [35:0] ic1eq2_ram [0:NUM_ELEMENTS-1];
    reg signed [35:0] ic2eq2_ram [0:NUM_ELEMENTS-1];

    //----------------------------------------------------------------
    // Per-element parameter RAM — SPI-writable (sclk write port below),
    // hex init is the boot image
    //
    //   p0[13:0]  pitch UQ4.10     p0[15:14] waveform
    //   p1[23:0]  duty  Q0.24 signed
    //   p2[13:0]  fc    UQ4.10     p2[31:14] q1 Q2.16 signed
    //   p3[7:0]   gain L UQ4.4     p3[15:8] gain R UQ4.4
    //   p3[16]    24 dB mode       p3[18:17] filter type
    //----------------------------------------------------------------
    // Doubled for ping-pong: {bank, voice} addressing, both halves
    // initialized to the boot image so an unwritten shadow is sane
    // (all-zeros would be 0 dB gains at pitch zero — NOT mute).
    reg [35:0] p0_ram [0:2*NUM_ELEMENTS-1];
    reg [35:0] p1_ram [0:2*NUM_ELEMENTS-1];
    reg [35:0] p2_ram [0:2*NUM_ELEMENTS-1];
    reg [35:0] p3_ram [0:2*NUM_ELEMENTS-1];

    // Pointer words: per-element bus pointers, three 10-bit fields
    // each. +5 (PTRS0): [9:0] pitch, [19:10] duty, [29:20] cutoff.
    // +6 (PTRS1): [9:0] Q, [19:10] gain L, [29:20] gain R. Pointers
    // are wiring, so they ride the ping-pong banks like every
    // parameter. Init 0: every parameter points at bus 0 (hardwired
    // zero), so boot behavior is exactly the pre-bus behavior.
    reg [29:0] p5_ram [0:2*NUM_ELEMENTS-1];
    reg [29:0] p6_ram [0:2*NUM_ELEMENTS-1];
    integer pi;
    initial for (pi = 0; pi < 2*NUM_ELEMENTS; pi = pi + 1) begin
        p5_ram[pi] = 30'd0;
        p6_ram[pi] = 30'd0;
    end

    // GATE word (map offset +4): [0] gate, [1] retrig (reserved).
    // Gate 0 silences the element (gain decode forced to exact mute);
    // the oscillator and filters free-run regardless — later this
    // edge becomes the ADSR trigger. Both banks boot gated ON so the
    // boot image keeps sounding (the power-up liveness check).
    reg [1:0] p4_ram [0:2*NUM_ELEMENTS-1];
    integer gi;
    initial for (gi = 0; gi < 2*NUM_ELEMENTS; gi = gi + 1)
        p4_ram[gi] = 2'b01;

    initial begin
        $readmemh(P0_HEX, p0_ram, 0, NUM_ELEMENTS-1);
        $readmemh(P1_HEX, p1_ram, 0, NUM_ELEMENTS-1);
        $readmemh(P2_HEX, p2_ram, 0, NUM_ELEMENTS-1);
        $readmemh(P3_HEX, p3_ram, 0, NUM_ELEMENTS-1);
        $readmemh(P0_HEX, p0_ram, NUM_ELEMENTS, 2*NUM_ELEMENTS-1);
        $readmemh(P1_HEX, p1_ram, NUM_ELEMENTS, 2*NUM_ELEMENTS-1);
        $readmemh(P2_HEX, p2_ram, NUM_ELEMENTS, 2*NUM_ELEMENTS-1);
        $readmemh(P3_HEX, p3_ram, NUM_ELEMENTS, 2*NUM_ELEMENTS-1);
    end

    //----------------------------------------------------------------
    // Bank control: active half (sysclk) flips at drum slot 512 when a
    // swap is pending; the sclk write side steers by a synced
    // complement of the active bank (memory map wording, literally).
    //----------------------------------------------------------------
    logic bank_active;
    logic sr_m, sr_s, sr_d;          // swap_req toggle sync (sysclk)
    logic swap_pending;

    initial begin
        bank_active  = 1'b0;
        {sr_m, sr_s, sr_d} = '0;
        swap_pending = 1'b0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_active  <= 1'b0;
            sr_m <= 1'b0; sr_s <= 1'b0; sr_d <= 1'b0;
            swap_pending <= 1'b0;
        end else begin
            sr_m <= swap_req;
            sr_s <= sr_m;
            sr_d <= sr_s;
            if (sr_s != sr_d)
                swap_pending <= 1'b1;
            else if (swap_pending && slot == synth_pkg::SWAP_SLOT[9:0]) begin
                bank_active  <= ~bank_active;
                swap_pending <= 1'b0;
            end
        end
    end

    // write side: shadow = complement of active, synced into sclk
    logic ba_m, ba_s;
    initial {ba_m, ba_s} = '0;
    always_ff @(posedge sclk) begin
        ba_m <= bank_active;
        ba_s <= ba_m;
    end
    wire bank_shadow = ~ba_s;

    // State RAMs start at zero (power-on init; also keeps X out of sim)
    integer i0;
    initial begin
        for (i0 = 0; i0 < NUM_ELEMENTS; i0 = i0 + 1) begin
            phase_ram[i0]  = '0;
            ic1eq1_ram[i0] = '0;
            ic2eq1_ram[i0] = '0;
            ic1eq2_ram[i0] = '0;
            ic2eq2_ram[i0] = '0;
        end
    end

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
    reg signed [17:0] bus_ram_pitch [0:synth_pkg::NUM_BUSES-1];
    reg signed [17:0] bus_ram_duty  [0:synth_pkg::NUM_BUSES-1];
    reg signed [17:0] bus_ram_fc    [0:synth_pkg::NUM_BUSES-1];
    reg signed [17:0] bus_ram_q     [0:synth_pkg::NUM_BUSES-1];
    reg signed [17:0] bus_ram_gl    [0:synth_pkg::NUM_BUSES-1];
    reg signed [17:0] bus_ram_gr    [0:synth_pkg::NUM_BUSES-1];
    integer bi;
    initial for (bi = 0; bi < synth_pkg::NUM_BUSES; bi = bi + 1) begin
        bus_ram_pitch[bi] = 18'sd0;
        bus_ram_duty[bi]  = 18'sd0;
        bus_ram_fc[bi]    = 18'sd0;
        bus_ram_q[bi]     = 18'sd0;
        bus_ram_gl[bi]    = 18'sd0;
        bus_ram_gr[bi]    = 18'sd0;
    end

    // SPI bus-base writes now land in a dedicated BASE RAM as well as
    // the value replicas: sinks read the replicas, the producer walker
    // reads the base and writes base + contribution into the replicas
    // (the spec's "bus = base register + producer contributions",
    // realized). A bus no producer targets keeps value = base via the
    // mailbox's own replica write.
    reg signed [17:0] bus_base [0:synth_pkg::NUM_BUSES-1];
    integer bbi;
    initial for (bbi = 0; bbi < synth_pkg::NUM_BUSES; bbi = bbi + 1)
        bus_base[bbi] = 18'sd0;

    // Producer walker replica-write strobes (driven below)
    logic               wk_wr;
    logic [9:0]         wk_bus;
    logic signed [17:0] wk_val;

    logic bwr_m, bwr_s, bwr_d;
    logic bw_pending;
    logic [9:0]  bwc_addr;
    logic [17:0] bwc_data;
    // Mailbox commits happen in any idle slot where the walker is not
    // writing the replicas THIS cycle (wk_wr below): lane reads issue
    // during slots 1..~257, and a commit colliding with a walker
    // write simply defers one cycle. The window stays ~500 slots
    // wide, so a 10 MHz SPI burst can never overrun the 1-deep
    // mailbox (word period 5.6 us >> max wait).
    wire  bus_idle   = (slot > 10'd258) && (slot < 10'd760);
    wire  bus_commit = bw_pending && bus_idle && !wk_wr
                       && (bwc_addr != 10'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bwr_m <= 1'b0; bwr_s <= 1'b0; bwr_d <= 1'b0;
            bw_pending <= 1'b0;
            bwc_addr <= '0; bwc_data <= '0;
        end else begin
            bwr_m <= bw_req; bwr_s <= bwr_m; bwr_d <= bwr_s;
            if (bwr_s != bwr_d) begin
                bw_pending <= 1'b1;         // payload is stable: it was
                bwc_addr   <= bw_addr;      // written before the toggle,
                bwc_data   <= bw_data;      // 2 sync FFs ago
            end else if (bw_pending && bus_idle) begin
                bw_pending <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk)
        if (bus_commit) bus_base[bwc_addr] <= $signed(bwc_data);

    // Replica writes: one physical port, two writers — the walker
    // owns its cycle (wk_wr), the mailbox defers around it.
    always_ff @(posedge clk)
        if (bus_commit)   bus_ram_pitch[bwc_addr] <= $signed(bwc_data);
        else if (wk_wr)   bus_ram_pitch[wk_bus]   <= wk_val;
    always_ff @(posedge clk)
        if (bus_commit)   bus_ram_duty[bwc_addr] <= $signed(bwc_data);
        else if (wk_wr)   bus_ram_duty[wk_bus]   <= wk_val;
    always_ff @(posedge clk)
        if (bus_commit)   bus_ram_fc[bwc_addr] <= $signed(bwc_data);
        else if (wk_wr)   bus_ram_fc[wk_bus]   <= wk_val;
    always_ff @(posedge clk)
        if (bus_commit)   bus_ram_q[bwc_addr] <= $signed(bwc_data);
        else if (wk_wr)   bus_ram_q[wk_bus]   <= wk_val;
    always_ff @(posedge clk)
        if (bus_commit)   bus_ram_gl[bwc_addr] <= $signed(bwc_data);
        else if (wk_wr)   bus_ram_gl[wk_bus]   <= wk_val;
    always_ff @(posedge clk)
        if (bus_commit)   bus_ram_gr[bwc_addr] <= $signed(bwc_data);
        else if (wk_wr)   bus_ram_gr[wk_bus]   <= wk_val;

    //----------------------------------------------------------------
    // Producer walker (B4/B5, bus_architecture.md) — the idle-slot
    // table executor. 128 entries × 3 config words (stride 4 in the
    // RAM), 3 slots per entry, span 300..~690. Law 1: the ONE
    // producer multiply sits alone in its own stage with registered
    // operands. Law 3: entries execute in table order, once per
    // sample. A producer's OUTPUT uses the PREVIOUS sample's state —
    // the one-sample lag is inaudible at control rates and it keeps
    // the sine's internal multiply and the producer multiply fed by
    // registers only.
    //
    // Per-entry phases (overlapped across entries):
    //   P0: read CFG + state
    //   P1: latch cfg/state; read RATES; read gate bus (bus_base)
    //   P2: next-state (adds/compares/shifts only); read DEPTH;
    //       source = LFO wave(old phase) | ADSR level (old);
    //       state writeback
    //   P3: source × depth (DSP, registered operands); read target
    //       base (bus_base — port shared with P1 by phase mux)
    //   P4: value = base + (product >>> 16), saturate, write replicas
    //
    // ADSR state word: [23:22] stage (0 idle, 1 attack, 2 decay/
    // sustain, 3 release), [21:0] level. Gate is LEVEL-sensitive on
    // the watched bus (> 0 = held): note-on/off is one live bus write.
    //----------------------------------------------------------------
    localparam [1:0] AST_IDLE = 2'd0, AST_ATT = 2'd1,
                     AST_DEC  = 2'd2, AST_REL = 2'd3;

    reg [35:0] prod_ram [0:8*synth_pkg::NUM_PRODUCERS-1]; // {bank,entry,word[1:0]}
    reg [23:0] prod_state [0:synth_pkg::NUM_PRODUCERS-1];
    integer wi;
    initial begin
        for (wi = 0; wi < 8*synth_pkg::NUM_PRODUCERS; wi = wi + 1)
            prod_ram[wi] = 36'd0;                  // type 0 = off
        for (wi = 0; wi < synth_pkg::NUM_PRODUCERS; wi = wi + 1)
            prod_state[wi] = 24'd0;
    end

    always_ff @(posedge sclk)
        if (pw_we) prod_ram[{bank_shadow, pw_addr}] <= {4'b0, pw_data};

    // control: 3-slot stride via a small counter, armed at slot 299
    logic [1:0] wcnt;
    logic [7:0] went;
    wire wk_run = (went < 8'(synth_pkg::NUM_PRODUCERS));
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wcnt <= 2'd0; went <= 8'hFF;
        end else if (slot == 10'd299) begin
            wcnt <= 2'd0; went <= 8'd0;
        end else if (wk_run) begin
            if (wcnt == 2'd2) begin
                wcnt <= 2'd0;
                went <= went + 8'd1;
            end else
                wcnt <= wcnt + 2'd1;
        end
    end
    wire wk_p0 = wk_run && (wcnt == 2'd0);

    // Sequential read registers: prod_ram serves CFG/RATES/DEPTH on
    // consecutive cycles through ONE register (address muxed by
    // phase); bus_base serves the gate read (P1) and the target-base
    // read (P3) through one register the same way.
    logic [35:0] wk_prod_q;
    logic [23:0] wk_st_q;
    logic signed [17:0] wk_busrd_q;
    logic        v0;               // a P0 read was issued last cycle

    // A stage — latched at the end of P1, stable for 3 cycles
    logic        eA_v;
    logic [6:0]  eA_e;
    logic [3:0]  eA_type;
    logic [1:0]  eA_shape;
    logic [9:0]  eA_tgt;
    logic [15:0] eA_rate;
    logic [23:0] stA;
    // B stage — latched at the end of P2
    logic        eB_v;
    logic [9:0]  eB_tgt;
    logic signed [17:0] srcB;
    // C stage — latched at the end of P3
    logic        eC_v;
    logic [9:0]  eC_tgt;
    logic signed [35:0] mC;

    // LFO waveform on the OLD phase (registered stA → rule-clean)
    logic signed [17:0] wk_wave;
    osc_core u_wk_osc (
        .phase      ($signed(stA)),
        .delta      (24'sd0),
        .duty       (24'sd0),
        .wave       (eA_shape),
        .phase_next (),
        .sample_out (wk_wave)
    );

    // next-state, computed at P2 (adds/compares/shifts only).
    // During P2, wk_prod_q holds the RATES word and wk_busrd_q holds
    // the gate-bus value (both read the cycle before).
    wire        wk_gate  = (wk_busrd_q > 18'sd0);
    wire [20:0] wk_ainc  = 21'((5'd16 + 5'(wk_prod_q[3:0]))
                               << wk_prod_q[7:4]);
    wire [20:0] wk_dinc  = 21'((5'd16 + 5'(wk_prod_q[11:8]))
                               << wk_prod_q[15:12]);
    wire [20:0] wk_rinc  = 21'((5'd16 + 5'(wk_prod_q[19:16]))
                               << wk_prod_q[23:20]);
    wire [21:0] wk_sus   = {wk_prod_q[31:24], 14'b0};
    wire [1:0]  a_stage  = stA[23:22];
    wire [21:0] a_level  = stA[21:0];
    logic [23:0] wk_nstate;
    always_comb begin
        if (eA_type == 4'd1) begin
            // LFO: free-running phase accumulator
            wk_nstate = stA + {8'b0, eA_rate};
        end else if (!wk_gate) begin
            // ADSR, gate low: release toward zero
            wk_nstate = (a_level > {1'b0, wk_rinc})
                ? {AST_REL, a_level - 22'(wk_rinc)}
                : {AST_IDLE, 22'd0};
        end else begin
            case (a_stage)
                AST_ATT: wk_nstate =
                    ({1'b0, a_level} + 23'(wk_ainc) > 23'h3FFFFF)
                        ? {AST_DEC, 22'h3FFFFF}
                        : {AST_ATT, a_level + 22'(wk_ainc)};
                AST_DEC: wk_nstate =
                    (a_level > wk_sus + 22'(wk_dinc))
                        ? {AST_DEC, a_level - 22'(wk_dinc)}
                        : (a_level > wk_sus) ? {AST_DEC, wk_sus}
                                             : {AST_DEC, a_level};
                default: wk_nstate = {AST_ATT, a_level};  // idle/release
            endcase
        end
    end

    // Phase-guarded stage latches: each stage latches only at its own
    // phase edge and stays stable for the entry's three cycles.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v0 <= 1'b0;
            eA_v <= 1'b0; eB_v <= 1'b0; eC_v <= 1'b0;
            eA_e <= '0; eA_type <= '0; eA_shape <= '0;
            eA_tgt <= '0; eA_rate <= '0; stA <= '0;
            eB_tgt <= '0; srcB <= '0;
            eC_tgt <= '0; mC <= '0;
        end else begin
            v0 <= wk_p0;

            if (wcnt == 2'd1) begin
                // end of P1: latch config (wk_prod_q = CFG) + state;
                // the previous entry's P4 just consumed eC
                eA_v     <= v0;
                eA_e     <= went[6:0];
                eA_type  <= wk_prod_q[3:0];
                eA_shape <= wk_prod_q[5:4];
                eA_tgt   <= wk_prod_q[15:6];
                eA_rate  <= wk_prod_q[31:16];
                stA      <= wk_st_q;
                eC_v     <= 1'b0;
            end else if (wcnt == 2'd2) begin
                // end of P2: source from OLD state; validity by type
                eB_v   <= eA_v && (eA_type == 4'd1 || eA_type == 4'd2);
                eB_tgt <= eA_tgt;
                srcB   <= (eA_type == 4'd1) ? wk_wave
                                            : $signed({2'b0, stA[21:6]});
                eA_v   <= 1'b0;
            end else begin
                // end of P3 (wcnt == 0): the producer multiply —
                // registered operands (srcB, and wk_prod_q = DEPTH)
                eC_v   <= eB_v;
                eC_tgt <= eB_tgt;
                mC     <= srcB * $signed(wk_prod_q[17:0]);
                eB_v   <= 1'b0;
            end
        end
    end

    // P4 (wcnt == 1): value = base + contribution, saturating.
    // wk_busrd_q holds the target base (read issued at P3).
    wire signed [19:0] wk_contrib = mC[35:16];
    wire signed [20:0] wk_sum =
        {{3{wk_busrd_q[17]}}, wk_busrd_q} + {wk_contrib[19], wk_contrib};
    assign wk_val = (wk_sum > 21'sd131071)  ? 18'sd131071  :
                    (wk_sum < -21'sd131072) ? -18'sd131072 : wk_sum[17:0];
    assign wk_bus = eC_tgt;
    assign wk_wr  = eC_v && (wcnt == 2'd1) && (eC_tgt != 10'd0);

    // walker memory reads — sync-only, one register per RAM, address
    // muxed by phase: prod_ram serves CFG (P0) / RATES (P1) /
    // DEPTH (P2); bus_base serves the gate bus (P1, address from the
    // CFG word just read) / the target base (P3).
    always_ff @(posedge clk) begin
        wk_prod_q  <= prod_ram[{bank_active, went[6:0], wcnt}];
        wk_st_q    <= prod_state[went[6:0]];
        wk_busrd_q <= bus_base[(wcnt == 2'd1) ? wk_prod_q[25:16]
                                              : eB_tgt];
    end
    always_ff @(posedge clk)
        if ((wcnt == 2'd2) && eA_v
            && (eA_type == 4'd1 || eA_type == 4'd2))
            prod_state[eA_e] <= wk_nstate;                      // P2

    //----------------------------------------------------------------
    // S0/S1 — RAM reads (address = element entering this cycle)
    //
    // Sync-only process: yosys memory inference (BSRAM read port).
    // Read data validity is gated by s1_act, so no reset is needed.
    //----------------------------------------------------------------
    logic [VW-1:0] raddr;
    assign raddr = lane_enter ? slot[VW-1:0] : '0;

    logic        s1_act;
    logic [VW-1:0] s1_idx;
    logic [13:0] s1_pitch;
    logic [1:0]  s1_wave;
    logic signed [23:0] s1_duty;
    logic [13:0] s1_fc;
    logic signed [17:0] s1_q1;
    logic [7:0]  s1_gl, s1_gr;
    logic        s1_dual;
    logic [1:0]  s1_ftype;
    logic signed [23:0] s1_phase;
    logic signed [35:0] s1_ic1eq1, s1_ic2eq1, s1_ic1eq2, s1_ic2eq2;

    // Param RAM reads are SYNCHRONOUS on clk (was a comb read into the
    // same registers — identical timing, but sync-read + separate-clock
    // write is the shape yosys infers as dual-clock BSRAM). Sync-only
    // process, per the AGENTS.md inference gotcha; validity is act-gated.
    logic [35:0] s1_p0, s1_p1, s1_p2, s1_p3;
    logic [1:0]  s1_p4;
    logic [29:0] s1_p5, s1_p6;
    always_ff @(posedge clk) begin
        s1_p0     <= p0_ram[{bank_active, raddr}];
        s1_p1     <= p1_ram[{bank_active, raddr}];
        s1_p2     <= p2_ram[{bank_active, raddr}];
        s1_p3     <= p3_ram[{bank_active, raddr}];
        s1_p4     <= p4_ram[{bank_active, raddr}];
        s1_p5     <= p5_ram[{bank_active, raddr}];
        s1_p6     <= p6_ram[{bank_active, raddr}];
        s1_phase  <= phase_ram[raddr];
        s1_ic1eq1 <= ic1eq1_ram[raddr];
        s1_ic2eq1 <= ic2eq1_ram[raddr];
        s1_ic1eq2 <= ic1eq2_ram[raddr];
        s1_ic2eq2 <= ic2eq2_ram[raddr];
    end

    // SPI-side write ports (sclk domain) — sync-only, one per bank
    always_ff @(posedge sclk)
        if (pe_we && pe_bank == 3'd0) p0_ram[{bank_shadow, pe_elem}] <= {4'b0, pe_wdata};
    always_ff @(posedge sclk)
        if (pe_we && pe_bank == 3'd1) p1_ram[{bank_shadow, pe_elem}] <= {4'b0, pe_wdata};
    always_ff @(posedge sclk)
        if (pe_we && pe_bank == 3'd2) p2_ram[{bank_shadow, pe_elem}] <= {4'b0, pe_wdata};
    always_ff @(posedge sclk)
        if (pe_we && pe_bank == 3'd3) p3_ram[{bank_shadow, pe_elem}] <= {4'b0, pe_wdata};
    always_ff @(posedge sclk)
        if (pe_we && pe_bank == 3'd4) p4_ram[{bank_shadow, pe_elem}] <= pe_wdata[1:0];
    always_ff @(posedge sclk)
        if (pe_we && pe_bank == 3'd5) p5_ram[{bank_shadow, pe_elem}] <= pe_wdata[29:0];
    always_ff @(posedge sclk)
        if (pe_we && pe_bank == 3'd6) p6_ram[{bank_shadow, pe_elem}] <= pe_wdata[29:0];

    // field views of the registered param words
    assign s1_pitch = s1_p0[13:0];
    assign s1_wave  = s1_p0[15:14];
    assign s1_duty  = s1_p1[23:0];
    assign s1_fc    = s1_p2[13:0];
    assign s1_q1    = s1_p2[31:14];
    // GATE off = exact-mute gain code into the existing mute machinery:
    // one decode-stage mux, no new carry registers down the pipeline.
    assign s1_gl    = s1_p4[0] ? s1_p3[7:0]  : 8'hFF;
    assign s1_gr    = s1_p4[0] ? s1_p3[15:8] : 8'hFF;
    assign s1_dual  = s1_p3[16];
    assign s1_ftype = s1_p3[18:17];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_act   <= 1'b0;
            s1_idx   <= '0;
        end else begin
            s1_act   <= lane_enter;
            s1_idx   <= slot[VW-1:0];
        end
    end

    //----------------------------------------------------------------
    // S2 — issue delta + K LUT reads; carry everything
    //----------------------------------------------------------------
    logic        s2_act;
    logic [VW-1:0] s2_idx;
    logic [13:0] s2_pitch;
    logic [1:0]  s2_wave;
    logic signed [23:0] s2_duty;
    logic [13:0] s2_fc;
    logic signed [17:0] s2_q1;
    logic [7:0]  s2_gl, s2_gr;
    logic        s2_dual;
    logic [1:0]  s2_ftype;
    logic signed [23:0] s2_phase;
    logic signed [35:0] s2_ic1eq1, s2_ic2eq1, s2_ic1eq2, s2_ic2eq2;

    // Bus fetches, one per sink: reads issued with the S1 pointers,
    // data lands at S2 alongside the base fields. Sync-only (one
    // BSRAM read port per replica).
    logic signed [17:0] s2_bus_pitch, s2_bus_duty, s2_bus_fc;
    logic signed [17:0] s2_bus_q, s2_bus_gl, s2_bus_gr;
    always_ff @(posedge clk) begin
        s2_bus_pitch <= bus_ram_pitch[s1_p5[9:0]];
        s2_bus_duty  <= bus_ram_duty[s1_p5[19:10]];
        s2_bus_fc    <= bus_ram_fc[s1_p5[29:20]];
        s2_bus_q     <= bus_ram_q[s1_p6[9:0]];
        s2_bus_gl    <= bus_ram_gl[s1_p6[19:10]];
        s2_bus_gr    <= bus_ram_gr[s1_p6[29:20]];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_act   <= 1'b0;
            s2_idx   <= '0;
            s2_pitch <= '0;
            s2_wave  <= '0;
            s2_duty  <= '0;
            s2_fc    <= '0;
            s2_q1    <= '0;
            s2_gl    <= '0;
            s2_gr    <= '0;
            s2_dual  <= 1'b0;
            s2_ftype <= '0;
            s2_phase <= '0;
            s2_ic1eq1 <= '0;
            s2_ic2eq1 <= '0;
            s2_ic1eq2 <= '0;
            s2_ic2eq2 <= '0;
        end else begin
            s2_act   <= s1_act;
            s2_idx   <= s1_idx;
            s2_pitch <= s1_pitch;
            s2_wave  <= s1_wave;
            s2_duty  <= s1_duty;
            s2_fc    <= s1_fc;
            s2_q1    <= s1_q1;
            s2_gl    <= s1_gl;
            s2_gr    <= s1_gr;
            s2_dual  <= s1_dual;
            s2_ftype <= s1_ftype;
            s2_phase <= s1_phase;
            s2_ic1eq1 <= s1_ic1eq1;
            s2_ic2eq1 <= s1_ic2eq1;
            s2_ic1eq2 <= s1_ic1eq2;
            s2_ic2eq2 <= s1_ic2eq2;
        end
    end

    //----------------------------------------------------------------
    // Effective parameters: base + bus[pointer], all SATURATING into
    // each parameter's legal range so extreme bus values clamp
    // instead of wrapping. Six parallel adders + clamps between S2
    // registers and S3 registers: adds/decode only, no multiply —
    // within the silicon timing rule. Per-sink slices of the Q8.10
    // bus word (bus_architecture.md law 5):
    //   pitch/cutoff: as-is (same LSB, ~1.17 cents)
    //   duty:  <<< 13 (bus ±1.0 → duty ±1.0 in Q0.24)
    //   Q:     <<< 6  (bus ±1.0 → q1 ±1.0 in Q2.16)
    //   gains: >>> 6  (bus 1 octave = 6 dB = 16 UQ4.4 steps; positive
    //          bus = more attenuation = quieter). A base of 0xFF
    //          (exact mute — hard-panned channels, gated elements) is
    //          preserved regardless of the bus.
    //----------------------------------------------------------------
    // Damping clamp, one end only (Thor): effective q1 in [0, Q1_MAX
    // = sqrt(2)]. Heavier-than-Butterworth damping is unreachable —
    // that is what makes FC_MAX safe. The floor is ZERO, not a
    // minimum: infinite Q / self-oscillation stays reachable as a
    // feature; only nonphysical negative damping is excluded.
    wire signed [24:0] q_sum =
        {{7{s2_q1[17]}}, s2_q1} + {s2_bus_q[17], s2_bus_q, 6'b0};
    wire signed [17:0] eff_q1 =
        q_sum[24] ? 18'sd0 :
        (q_sum > 25'($signed({7'b0, synth_pkg::Q1_MAX})))
            ? $signed(synth_pkg::Q1_MAX) :
        q_sum[17:0];

    // Cutoff clamps to the flat FC_MAX (14.4 kHz, measured clean at
    // the Butterworth worst case — see synth_pkg).
    wire signed [18:0] fc_sum =
        $signed({5'b0, s2_fc}) + {s2_bus_fc[17], s2_bus_fc};
    wire [13:0] eff_fc =
        fc_sum[18] ? 14'd0 :
        (fc_sum > 19'($signed({5'b0, synth_pkg::FC_MAX})))
            ? synth_pkg::FC_MAX :
        fc_sum[13:0];

    wire signed [18:0] pitch_sum =
        $signed({5'b0, s2_pitch}) + {s2_bus_pitch[17], s2_bus_pitch};
    wire [13:0] eff_pitch =
        pitch_sum[18]            ? 14'd0    :
        (pitch_sum > 19'sd16383) ? 14'h3FFF : pitch_sum[13:0];

    wire signed [31:0] duty_sum =
        {{8{s2_duty[23]}}, s2_duty}
        + {{1{s2_bus_duty[17]}}, s2_bus_duty, 13'b0};
    wire signed [23:0] eff_duty =
        (duty_sum >  32'sd8388607) ? 24'sd8388607  :
        (duty_sum < -32'sd8388608) ? -24'sd8388608 : duty_sum[23:0];

    wire signed [17:0] gbus_l = s2_bus_gl >>> 6;
    wire signed [17:0] gbus_r = s2_bus_gr >>> 6;
    wire signed [18:0] gl_sum =
        $signed({11'b0, s2_gl}) + {gbus_l[17], gbus_l};
    wire signed [18:0] gr_sum =
        $signed({11'b0, s2_gr}) + {gbus_r[17], gbus_r};
    wire [7:0] eff_gl =
        (s2_gl == 8'hFF)      ? 8'hFF :
        gl_sum[18]            ? 8'h00 :
        (gl_sum > 19'sd254)   ? 8'hFE : gl_sum[7:0];
    wire [7:0] eff_gr =
        (s2_gr == 8'hFF)      ? 8'hFF :
        gr_sum[18]            ? 8'h00 :
        (gr_sum > 19'sd254)   ? 8'hFE : gr_sum[7:0];

    //----------------------------------------------------------------
    // S3 — LUT data, delta/K, phase_next, oscillator waveform
    //----------------------------------------------------------------
    logic [23:0] s3_delta_lut;
    logic [15:0] s3_k_lut;

    logic        s3_act;
    logic [VW-1:0] s3_idx;
    logic signed [23:0] s3_phase;
    logic [3:0]  s3_pitch_oct;
    logic [3:0]  s3_fc_oct;
    logic [1:0]  s3_wave;
    logic signed [23:0] s3_duty;
    logic signed [17:0] s3_q1;
    logic [7:0]  s3_gl, s3_gr;
    logic        s3_dual;
    logic [1:0]  s3_ftype;
    logic signed [35:0] s3_ic1eq1, s3_ic2eq1, s3_ic1eq2, s3_ic2eq2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_delta_lut <= '0;
            s3_k_lut     <= '0;
            s3_act   <= 1'b0;
            s3_idx   <= '0;
            s3_phase <= '0;
            s3_pitch_oct <= '0;
            s3_fc_oct    <= '0;
            s3_wave  <= '0;
            s3_duty  <= '0;
            s3_q1    <= '0;
            s3_gl    <= '0;
            s3_gr    <= '0;
            s3_dual  <= 1'b0;
            s3_ftype <= '0;
            s3_ic1eq1 <= '0;
            s3_ic2eq1 <= '0;
            s3_ic1eq2 <= '0;
            s3_ic2eq2 <= '0;
        end else begin
            s3_delta_lut <= phase_lut[eff_pitch[9:0]];
            s3_k_lut     <= k_lut[eff_fc[9:0]];
            s3_act   <= s2_act;
            s3_idx   <= s2_idx;
            s3_phase <= s2_phase;
            s3_pitch_oct <= eff_pitch[13:10];
            s3_fc_oct    <= eff_fc[13:10];
            s3_wave  <= s2_wave;
            s3_duty  <= eff_duty;
            s3_q1    <= eff_q1;
            s3_gl    <= eff_gl;
            s3_gr    <= eff_gr;
            s3_dual  <= s2_dual;
            s3_ftype <= s2_ftype;
            s3_ic1eq1 <= s2_ic1eq1;
            s3_ic2eq1 <= s2_ic2eq1;
            s3_ic1eq2 <= s2_ic1eq2;
            s3_ic2eq2 <= s2_ic2eq2;
        end
    end

    // S3 combinational datapath
    logic signed [23:0] delta;
    logic signed [35:0] k;
    logic signed [17:0] osc_sample;

    assign delta = $signed(s3_delta_lut) >>> (11 - s3_pitch_oct);
    // K stays full-width — do NOT narrow to 18-bit to save DSPs: the
    // LUT+shift expands to ~22+ bits of real precision, needed later
    // for the noise oscillator and whistling-filter melodies (Thor).
    assign k     = $signed({20'd0, s3_k_lut}) <<< (3 + s3_fc_oct);

    osc_core u_osc (
        .phase      (s3_phase),
        .delta      (delta),
        .duty       (s3_duty),
        .wave       (s3_wave),
        .phase_next (),
        .sample_out (osc_sample)
    );

    //----------------------------------------------------------------
    // S3B — register the shifted K, oscillator sample and phase add,
    // so S4's multiplies see registered operands only (the silicon
    // timing rule: never chain a barrel shift into a DSP multiply)
    //----------------------------------------------------------------
    logic        s3b_act;
    logic [VW-1:0] s3b_idx;
    logic signed [35:0] s3b_k;
    logic signed [17:0] s3b_osc;
    logic signed [23:0] s3b_phase;        // phase_next (writeback)
    logic signed [17:0] s3b_q1;
    logic signed [35:0] s3b_ic1eq1, s3b_ic2eq1, s3b_ic1eq2, s3b_ic2eq2;
    logic [7:0]  s3b_gl, s3b_gr;
    logic        s3b_dual;
    logic [1:0]  s3b_ftype;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3b_act  <= 1'b0;
            s3b_idx  <= '0;
            s3b_k    <= '0;
            s3b_osc  <= '0;
            s3b_phase <= '0;
            s3b_q1   <= '0;
            s3b_ic1eq1 <= '0;
            s3b_ic2eq1 <= '0;
            s3b_ic1eq2 <= '0;
            s3b_ic2eq2 <= '0;
            s3b_gl   <= '0;
            s3b_gr   <= '0;
            s3b_dual <= 1'b0;
            s3b_ftype <= '0;
        end else begin
            s3b_act  <= s3_act;
            s3b_idx  <= s3_idx;
            s3b_k    <= k;
            s3b_osc  <= osc_sample;
            s3b_phase <= s3_phase + delta;
            s3b_q1   <= s3_q1;
            s3b_ic1eq1 <= s3_ic1eq1;
            s3b_ic2eq1 <= s3_ic2eq1;
            s3b_ic1eq2 <= s3_ic1eq2;
            s3b_ic2eq2 <= s3_ic2eq2;
            s3b_gl   <= s3_gl;
            s3b_gr   <= s3_gr;
            s3b_dual <= s3_dual;
            s3b_ftype <= s3_ftype;
        end
    end

    //----------------------------------------------------------------
    // S4 — SVF1 stage A: m1 = K*ic1eq1, m2 = q1*ic1eq1  (DSP)
    //----------------------------------------------------------------
    logic        s4_act;
    logic [VW-1:0] s4_idx;
    logic signed [71:0] s4_m1, s4_m2;
    logic signed [17:0] s4_osc;
    logic signed [23:0] s4_phase;         // phase_next (writeback)
    logic signed [35:0] s4_k;
    logic signed [17:0] s4_q1;
    logic signed [35:0] s4_ic1eq1, s4_ic2eq1;   // old states
    logic signed [35:0] s4_ic1eq2, s4_ic2eq2;
    logic [7:0]  s4_gl, s4_gr;
    logic        s4_dual;
    logic [1:0]  s4_ftype;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s4_act  <= 1'b0;
            s4_idx  <= '0;
            s4_m1   <= '0;
            s4_m2   <= '0;
            s4_osc  <= '0;
            s4_phase <= '0;
            s4_k    <= '0;
            s4_q1   <= '0;
            s4_ic1eq1 <= '0;
            s4_ic2eq1 <= '0;
            s4_ic1eq2 <= '0;
            s4_ic2eq2 <= '0;
            s4_gl   <= '0;
            s4_gr   <= '0;
            s4_dual <= 1'b0;
            s4_ftype <= '0;
        end else begin
            s4_act  <= s3b_act;
            s4_idx  <= s3b_idx;
            s4_m1   <= s3b_k * s3b_ic1eq1;
            s4_m2   <= (s3b_q1 <<< 12) * s3b_ic1eq1;   // Q2.16 → Q8.28
            s4_osc  <= s3b_osc;
            s4_phase <= s3b_phase;
            s4_k    <= s3b_k;
            s4_q1   <= s3b_q1;
            s4_ic1eq1 <= s3b_ic1eq1;
            s4_ic2eq1 <= s3b_ic2eq1;
            s4_ic1eq2 <= s3b_ic1eq2;
            s4_ic2eq2 <= s3b_ic2eq2;
            s4_gl   <= s3b_gl;
            s4_gr   <= s3b_gr;
            s4_dual <= s3b_dual;
            s4_ftype <= s3b_ftype;
        end
    end

    //----------------------------------------------------------------
    // S5 — SVF1 stage B: lp1/hp1, m3 = K*hp1  (DSP)
    //----------------------------------------------------------------
    logic        s5_act;
    logic [VW-1:0] s5_idx;
    logic signed [35:0] s5_lp1, s5_hp1;
    logic signed [35:0] s5_ic1eq1;         // old ic1eq1, for bp1
    logic signed [35:0] s5_ic1eq2, s5_ic2eq2;
    logic signed [35:0] s5_k;
    logic signed [17:0] s5_q1;
    logic signed [23:0] s5_phase;
    logic [7:0]  s5_gl, s5_gr;
    logic        s5_dual;
    logic [1:0]  s5_ftype;

    // Audio enters the filter at TRUE Q8.28: Q2.16 <<< 12, leaving the
    // 8 integer bits (±128 vs a ±1 signal) as overshoot headroom.  The
    // original <<< 18 injected the signal 64× hot, so at any cutoff
    // below the input's energy the hp sum (in − lp − q·bp, three
    // near-full-scale terms) wrapped the 36-bit state and the wrap fed
    // back — noise for every FC below ~14 kHz, stable only wide open.
    logic signed [35:0] lp1, hp1;
    always_comb begin
        lp1 = s4_ic2eq1 + (s4_m1 >>> 28);
        hp1 = (s4_osc <<< 12) - lp1 - (s4_m2 >>> 28);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s5_act  <= 1'b0;
            s5_idx  <= '0;
            s5_lp1  <= '0;
            s5_hp1  <= '0;
            s5_ic1eq1 <= '0;
            s5_ic1eq2 <= '0;
            s5_ic2eq2 <= '0;
            s5_k    <= '0;
            s5_q1   <= '0;
            s5_phase <= '0;
            s5_gl   <= '0;
            s5_gr   <= '0;
            s5_dual <= 1'b0;
            s5_ftype <= '0;
        end else begin
            s5_act  <= s4_act;
            s5_idx  <= s4_idx;
            s5_lp1  <= lp1;
            s5_hp1  <= hp1;
            s5_ic1eq1 <= s4_ic1eq1;
            s5_ic1eq2 <= s4_ic1eq2;
            s5_ic2eq2 <= s4_ic2eq2;
            s5_k    <= s4_k;
            s5_q1   <= s4_q1;
            s5_phase <= s4_phase;
            s5_gl   <= s4_gl;
            s5_gr   <= s4_gr;
            s5_dual <= s4_dual;
            s5_ftype <= s4_ftype;
        end
    end

    //----------------------------------------------------------------
    // S5B — SVF1 stage B2: m3 = K*hp1, on REGISTERED hp1  (DSP)
    //
    // This stage exists because chaining the S5 adder tree straight
    // into the 36×36 multiply violated setup on real silicon at
    // 98.304 MHz for the long-carry operand patterns low cutoffs
    // produce (nextpnr's timing model passed it; the bench disagreed:
    // sparse single-sample corruption — "rain on a metal roof" — that
    // vanished at half clock). One register between adds and multiply
    // makes every stage adds-only or multiply-only.
    //----------------------------------------------------------------
    logic        s5b_act;
    logic [VW-1:0] s5b_idx;
    logic signed [35:0] s5b_lp1, s5b_hp1;
    logic signed [71:0] s5b_m3;
    logic signed [35:0] s5b_ic1eq1;
    logic signed [35:0] s5b_ic1eq2, s5b_ic2eq2;
    logic signed [35:0] s5b_k;
    logic signed [17:0] s5b_q1;
    logic signed [23:0] s5b_phase;
    logic [7:0]  s5b_gl, s5b_gr;
    logic        s5b_dual;
    logic [1:0]  s5b_ftype;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s5b_act  <= 1'b0;
            s5b_idx  <= '0;
            s5b_lp1  <= '0;
            s5b_hp1  <= '0;
            s5b_m3   <= '0;
            s5b_ic1eq1 <= '0;
            s5b_ic1eq2 <= '0;
            s5b_ic2eq2 <= '0;
            s5b_k    <= '0;
            s5b_q1   <= '0;
            s5b_phase <= '0;
            s5b_gl   <= '0;
            s5b_gr   <= '0;
            s5b_dual <= 1'b0;
            s5b_ftype <= '0;
        end else begin
            s5b_act  <= s5_act;
            s5b_idx  <= s5_idx;
            s5b_lp1  <= s5_lp1;
            s5b_hp1  <= s5_hp1;
            s5b_m3   <= s5_k * s5_hp1;
            s5b_ic1eq1 <= s5_ic1eq1;
            s5b_ic1eq2 <= s5_ic1eq2;
            s5b_ic2eq2 <= s5_ic2eq2;
            s5b_k    <= s5_k;
            s5b_q1   <= s5_q1;
            s5b_phase <= s5_phase;
            s5b_gl   <= s5_gl;
            s5b_gr   <= s5_gr;
            s5b_dual <= s5_dual;
            s5b_ftype <= s5_ftype;
        end
    end

    //----------------------------------------------------------------
    // S6 — SVF1 stage C: bp1, new states, filter-1 output
    //----------------------------------------------------------------
    logic        s6_act;
    logic [VW-1:0] s6_idx;
    logic signed [17:0] s6_f1;             // filter-1 out, Q2.16
    logic signed [35:0] s6_ic1eq1n, s6_ic2eq1n;   // updated states
    logic signed [35:0] s6_ic1eq2, s6_ic2eq2;
    logic signed [35:0] s6_k;
    logic signed [17:0] s6_q1;
    logic signed [23:0] s6_phase;
    logic [7:0]  s6_gl, s6_gr;
    logic        s6_dual;
    logic [1:0]  s6_ftype;

    // Q8.28 → Q2.16 with saturation: with real state headroom, resonant
    // peaks can legitimately exceed the ±2 output range and must clamp,
    // not wrap.
    function automatic logic signed [17:0] sat_q216(input logic signed [35:0] x);
        logic signed [35:0] s;
        begin
            s = x >>> 12;                       // Q8.28 → Q8.16
            if (s > 36'sd131071)        sat_q216 = 18'sd131071;
            else if (s < -36'sd131072)  sat_q216 = -18'sd131072;
            else                        sat_q216 = s[17:0];
        end
    endfunction

    logic signed [35:0] bp1;
    logic signed [35:0] f1_36;
    always_comb begin
        bp1 = (s5b_m3 >>> 28) + s5b_ic1eq1;
        case (s5b_ftype)
            2'd1:    f1_36 = bp1;
            2'd2:    f1_36 = s5b_hp1;
            default: f1_36 = s5b_lp1;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s6_act  <= 1'b0;
            s6_idx  <= '0;
            s6_f1   <= '0;
            s6_ic1eq1n <= '0;
            s6_ic2eq1n <= '0;
            s6_ic1eq2 <= '0;
            s6_ic2eq2 <= '0;
            s6_k    <= '0;
            s6_q1   <= '0;
            s6_phase <= '0;
            s6_gl   <= '0;
            s6_gr   <= '0;
            s6_dual <= 1'b0;
            s6_ftype <= '0;
        end else begin
            s6_act  <= s5b_act;
            s6_idx  <= s5b_idx;
            s6_f1   <= sat_q216(f1_36);
            s6_ic1eq1n <= bp1;
            s6_ic2eq1n <= s5b_lp1;
            s6_ic1eq2 <= s5b_ic1eq2;
            s6_ic2eq2 <= s5b_ic2eq2;
            s6_k    <= s5b_k;
            s6_q1   <= s5b_q1;
            s6_phase <= s5b_phase;
            s6_gl   <= s5b_gl;
            s6_gr   <= s5b_gr;
            s6_dual <= s5b_dual;
            s6_ftype <= s5b_ftype;
        end
    end

    //----------------------------------------------------------------
    // S7 — SVF2 stage A: m4 = K*ic1eq2, m5 = q1*ic1eq2  (DSP)
    //----------------------------------------------------------------
    logic        s7_act;
    logic [VW-1:0] s7_idx;
    logic signed [71:0] s7_m4, s7_m5;
    logic signed [17:0] s7_f1;
    logic signed [35:0] s7_ic1eq2, s7_ic2eq2;   // old states
    logic signed [35:0] s7_k;
    logic signed [35:0] s7_ic1eq1n, s7_ic2eq1n;
    logic signed [23:0] s7_phase;
    logic [7:0]  s7_gl, s7_gr;
    logic        s7_dual;
    logic [1:0]  s7_ftype;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s7_act  <= 1'b0;
            s7_idx  <= '0;
            s7_m4   <= '0;
            s7_m5   <= '0;
            s7_f1   <= '0;
            s7_ic1eq2 <= '0;
            s7_ic2eq2 <= '0;
            s7_k    <= '0;
            s7_ic1eq1n <= '0;
            s7_ic2eq1n <= '0;
            s7_phase <= '0;
            s7_gl   <= '0;
            s7_gr   <= '0;
            s7_dual <= 1'b0;
            s7_ftype <= '0;
        end else begin
            s7_act  <= s6_act;
            s7_idx  <= s6_idx;
            s7_m4   <= s6_k * s6_ic1eq2;
            s7_m5   <= (s6_q1 <<< 12) * s6_ic1eq2;   // Q2.16 → Q8.28
            s7_f1   <= s6_f1;
            s7_ic1eq2 <= s6_ic1eq2;
            s7_ic2eq2 <= s6_ic2eq2;
            s7_k    <= s6_k;
            s7_ic1eq1n <= s6_ic1eq1n;
            s7_ic2eq1n <= s6_ic2eq1n;
            s7_phase <= s6_phase;
            s7_gl   <= s6_gl;
            s7_gr   <= s6_gr;
            s7_dual <= s6_dual;
            s7_ftype <= s6_ftype;
        end
    end

    //----------------------------------------------------------------
    // S8 — SVF2 stage B: lp2/hp2, m6 = K*hp2  (DSP)
    //----------------------------------------------------------------
    logic        s8_act;
    logic [VW-1:0] s8_idx;
    logic signed [35:0] s8_lp2, s8_hp2;
    logic signed [35:0] s8_k;
    logic signed [35:0] s8_ic1eq2;         // old ic1eq2, for bp2
    logic signed [35:0] s8_ic1eq1n, s8_ic2eq1n;
    logic signed [17:0] s8_f1;
    logic signed [23:0] s8_phase;
    logic [7:0]  s8_gl, s8_gr;
    logic        s8_dual;
    logic [1:0]  s8_ftype;

    logic signed [35:0] lp2, hp2;
    always_comb begin
        lp2 = s7_ic2eq2 + (s7_m4 >>> 28);
        hp2 = (s7_f1 <<< 12) - lp2 - (s7_m5 >>> 28);   // true Q8.28, as SVF1
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s8_act  <= 1'b0;
            s8_idx  <= '0;
            s8_lp2  <= '0;
            s8_hp2  <= '0;
            s8_k    <= '0;
            s8_ic1eq2 <= '0;
            s8_ic1eq1n <= '0;
            s8_ic2eq1n <= '0;
            s8_f1   <= '0;
            s8_phase <= '0;
            s8_gl   <= '0;
            s8_gr   <= '0;
            s8_dual <= 1'b0;
            s8_ftype <= '0;
        end else begin
            s8_act  <= s7_act;
            s8_idx  <= s7_idx;
            s8_lp2  <= lp2;
            s8_hp2  <= hp2;
            s8_k    <= s7_k;
            s8_ic1eq2 <= s7_ic1eq2;
            s8_ic1eq1n <= s7_ic1eq1n;
            s8_ic2eq1n <= s7_ic2eq1n;
            s8_f1   <= s7_f1;
            s8_phase <= s7_phase;
            s8_gl   <= s7_gl;
            s8_gr   <= s7_gr;
            s8_dual <= s7_dual;
            s8_ftype <= s7_ftype;
        end
    end

    //----------------------------------------------------------------
    // S8B — SVF2 stage B2: m6 = K*hp2, on REGISTERED hp2  (DSP)
    // Same setup-timing reasoning as S5B.
    //----------------------------------------------------------------
    logic        s8b_act;
    logic [VW-1:0] s8b_idx;
    logic signed [35:0] s8b_lp2, s8b_hp2;
    logic signed [71:0] s8b_m6;
    logic signed [35:0] s8b_ic1eq2;
    logic signed [35:0] s8b_ic1eq1n, s8b_ic2eq1n;
    logic signed [17:0] s8b_f1;
    logic signed [23:0] s8b_phase;
    logic [7:0]  s8b_gl, s8b_gr;
    logic        s8b_dual;
    logic [1:0]  s8b_ftype;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s8b_act  <= 1'b0;
            s8b_idx  <= '0;
            s8b_lp2  <= '0;
            s8b_hp2  <= '0;
            s8b_m6   <= '0;
            s8b_ic1eq2 <= '0;
            s8b_ic1eq1n <= '0;
            s8b_ic2eq1n <= '0;
            s8b_f1   <= '0;
            s8b_phase <= '0;
            s8b_gl   <= '0;
            s8b_gr   <= '0;
            s8b_dual <= 1'b0;
            s8b_ftype <= '0;
        end else begin
            s8b_act  <= s8_act;
            s8b_idx  <= s8_idx;
            s8b_lp2  <= s8_lp2;
            s8b_hp2  <= s8_hp2;
            s8b_m6   <= s8_k * s8_hp2;
            s8b_ic1eq2 <= s8_ic1eq2;
            s8b_ic1eq1n <= s8_ic1eq1n;
            s8b_ic2eq1n <= s8_ic2eq1n;
            s8b_f1   <= s8_f1;
            s8b_phase <= s8_phase;
            s8b_gl   <= s8_gl;
            s8b_gr   <= s8_gr;
            s8b_dual <= s8_dual;
            s8b_ftype <= s8_ftype;
        end
    end

    //----------------------------------------------------------------
    // S9 — SVF2 stage C: bp2, new states, filter-2 output, element out
    //----------------------------------------------------------------
    logic        s9_act;
    logic [VW-1:0] s9_idx;
    logic signed [17:0] s9_elem;          // Q2.16
    logic signed [23:0] s9_phase;
    logic signed [35:0] s9_ic1eq1n, s9_ic2eq1n;
    logic signed [35:0] s9_ic1eq2n, s9_ic2eq2n;
    logic [7:0]  s9_gl, s9_gr;

    logic signed [35:0] bp2;
    logic signed [35:0] f2_36;
    always_comb begin
        bp2 = (s8b_m6 >>> 28) + s8b_ic1eq2;
        case (s8b_ftype)
            2'd1:    f2_36 = bp2;
            2'd2:    f2_36 = s8b_hp2;
            default: f2_36 = s8b_lp2;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s9_act  <= 1'b0;
            s9_idx  <= '0;
            s9_elem <= '0;
            s9_phase <= '0;
            s9_ic1eq1n <= '0;
            s9_ic2eq1n <= '0;
            s9_ic1eq2n <= '0;
            s9_ic2eq2n <= '0;
            s9_gl   <= '0;
            s9_gr   <= '0;
        end else begin
            s9_act  <= s8b_act;
            s9_idx  <= s8b_idx;
            s9_elem <= s8b_dual ? sat_q216(f2_36) : s8b_f1;
            s9_phase <= s8b_phase;
            s9_ic1eq1n <= s8b_ic1eq1n;
            s9_ic2eq1n <= s8b_ic2eq1n;
            s9_ic1eq2n <= bp2;
            s9_ic2eq2n <= s8b_lp2;
            s9_gl   <= s8b_gl;
            s9_gr   <= s8b_gr;
        end
    end

    //----------------------------------------------------------------
    // S9B — attenuation decode: lin = att_lut[frac] >>> int, REGISTERED
    //
    //   gain UQ4.4: att_lut[i] = 2^(-i/16) in UQ0.16 → 6 dB per int
    //   step, 0.375 dB per frac step.
    //
    // Split from the multiply for the same silicon-timing reason as
    // S5B/S8B: LUT read + 16-position barrel shift chained into a DSP
    // multiply in one cycle violated setup at 98.304 MHz — audibly, on
    // whichever channel drew the longer route (the right, on this
    // build), and clean at half clock. Decode and multiply are now
    // separate stages.
    //----------------------------------------------------------------
    logic        s9b_act;
    logic [VW-1:0] s9b_idx;
    logic signed [17:0] s9b_elem;
    logic signed [17:0] s9b_lin_l, s9b_lin_r;
    logic signed [23:0] s9b_phase;
    logic signed [35:0] s9b_ic1eq1n, s9b_ic2eq1n, s9b_ic1eq2n, s9b_ic2eq2n;

    // Gain 0xFF is EXACT mute, not -96 dB: the log decode bottoms out at
    // lin = 1 LSB, and 256 correlated muted elements sum 48 dB of that
    // right back (measured: -48 dBFS of ghost organ). A muted voice
    // must contribute zero.
    logic signed [17:0] lin_l, lin_r;
    always_comb begin
        lin_l = (s9_gl == 8'hFF) ? 18'sd0
              : 18'($signed({1'b0, att_lut[s9_gl[3:0]]})) >>> s9_gl[7:4];
        lin_r = (s9_gr == 8'hFF) ? 18'sd0
              : 18'($signed({1'b0, att_lut[s9_gr[3:0]]})) >>> s9_gr[7:4];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s9b_act  <= 1'b0;
            s9b_idx  <= '0;
            s9b_elem <= '0;
            s9b_lin_l <= '0;
            s9b_lin_r <= '0;
            s9b_phase <= '0;
            s9b_ic1eq1n <= '0;
            s9b_ic2eq1n <= '0;
            s9b_ic1eq2n <= '0;
            s9b_ic2eq2n <= '0;
        end else begin
            s9b_act  <= s9_act;
            s9b_idx  <= s9_idx;
            s9b_elem <= s9_elem;
            s9b_lin_l <= lin_l;
            s9b_lin_r <= lin_r;
            s9b_phase <= s9_phase;
            s9b_ic1eq1n <= s9_ic1eq1n;
            s9b_ic2eq1n <= s9_ic2eq1n;
            s9b_ic1eq2n <= s9_ic1eq2n;
            s9b_ic2eq2n <= s9_ic2eq2n;
        end
    end

    //----------------------------------------------------------------
    // S10 — attenuation multiply on REGISTERED operands  (DSP)
    //----------------------------------------------------------------
    logic        s10_act;
    logic [VW-1:0] s10_idx;
    logic signed [17:0] s10_outl, s10_outr;
    logic signed [23:0] s10_phase;
    logic signed [35:0] s10_ic1eq1n, s10_ic2eq1n, s10_ic1eq2n, s10_ic2eq2n;

    logic signed [34:0] prod_l, prod_r;
    always_comb begin
        prod_l = s9b_elem * s9b_lin_l;
        prod_r = s9b_elem * s9b_lin_r;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s10_act  <= 1'b0;
            s10_idx  <= '0;
            s10_outl <= '0;
            s10_outr <= '0;
            s10_phase <= '0;
            s10_ic1eq1n <= '0;
            s10_ic2eq1n <= '0;
            s10_ic1eq2n <= '0;
            s10_ic2eq2n <= '0;
        end else begin
            s10_act  <= s9b_act;
            s10_idx  <= s9b_idx;
            s10_outl <= prod_l >>> 16;
            s10_outr <= prod_r >>> 16;
            s10_phase <= s9b_phase;
            s10_ic1eq1n <= s9b_ic1eq1n;
            s10_ic2eq1n <= s9b_ic2eq1n;
            s10_ic1eq2n <= s9b_ic1eq2n;
            s10_ic2eq2n <= s9b_ic2eq2n;
        end
    end

    //----------------------------------------------------------------
    // S11 — mix accumulate + state writeback
    //
    // Mixdown headroom: 256 elements × Q2.16 (±2.0) needs 8 guard bits,
    // so the accumulator is 26-bit and can never overflow even with
    // all elements coherent and full-scale.  The output limiter (sat24)
    // converts Q2.16 → Q0.24 (<< 8) and clips only in the pathological
    // all-256-elements-aligned case; overall loudness is set by the
    // per-element UQ4.4 gains (boot image: -36 dB/element → 8 unison elements
    // aligned reach exactly 1/8 FS per note).
    //----------------------------------------------------------------
    function automatic logic signed [23:0] sat24(input logic signed [33:0] x);
        if (x > 33'sd8388607)
            sat24 = 24'sd8388607;
        else if (x < -33'sd8388608)
            sat24 = -24'sd8388608;
        else
            sat24 = x[23:0];
    endfunction

    logic signed [25:0] mix_l_acc, mix_r_acc;   // Q2.16 + 8 guard bits

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mix_l_acc  <= '0;
            mix_r_acc  <= '0;
            mix_left   <= '0;
            mix_right  <= '0;
        end else begin
            if (sample_tick) begin
                // sample boundary: publish the finished sum, start fresh
                mix_left   <= sat24(mix_l_acc <<< 8);   // Q2.16 → Q0.24
                mix_right  <= sat24(mix_r_acc <<< 8);
                mix_l_acc  <= '0;
                mix_r_acc  <= '0;
            end else if (s10_act) begin
                mix_l_acc <= mix_l_acc + {{8{s10_outl[17]}}, s10_outl};
                mix_r_acc <= mix_r_acc + {{8{s10_outr[17]}}, s10_outr};
            end
        end
    end

    // State writeback — sync-only process (BSRAM write port).
    // Writeback lands 13 cycles after the read (S5B/S8B added), so
    // read and write addresses can never collide (13 < 256).
    always_ff @(posedge clk) begin
        if (s10_act) begin
            phase_ram[s10_idx]  <= s10_phase;
            ic1eq1_ram[s10_idx] <= s10_ic1eq1n;
            ic2eq1_ram[s10_idx] <= s10_ic2eq1n;
            ic1eq2_ram[s10_idx] <= s10_ic1eq2n;
            ic2eq2_ram[s10_idx] <= s10_ic2eq2n;
        end
    end

endmodule
