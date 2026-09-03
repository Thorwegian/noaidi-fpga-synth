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
    input  logic           elem_write_enable,
    input  logic [2:0]     elem_write_word,     // 0..6 = p0..p3, GATE, PTRS0, PTRS1

    // Bus-write mailbox from spi_bus (sclk-domain toggle + payload).
    // Synced here and committed to bus RAM only in an idle drum slot,
    // so a commit never collides with a lane's bus read.
    input  logic [9:0]     bus_write_addr,
    input  logic [17:0]    bus_write_data,
    input  logic           bus_write_toggle,

    // Producer table writes (sclk domain, banked — wiring per law 4)
    input  logic           producer_write_enable,
    input  logic [8:0]     producer_write_addr,     // {entry[6:0], word[1:0]}
    input  logic [31:0]    producer_write_data,
    input  logic [7:0]     elem_write_index,
    input  logic [31:0]    elem_write_data,
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
    reg [16:0] q1_lut    [0:15];       // SVF damping mantissa, one
                                       // octave of the log2 resonance
                                       // code (q1 = sqrt2 * 2^-r) in
                                       // 1/16-octave steps — the
                                       // attenuation-LUT grid, ear-
                                       // proven for loudness-class
                                       // percepts (issue #41); fabric
                                       // LUTs, no BSRAM block
    reg [16:0] att_lut   [0:15];       // log-gain fractional part

    initial begin
        $readmemh("element/phase_lut.hex", phase_lut);
        $readmemh("element/svf_k_lut.hex", k_lut);
        $readmemh("element/q1_lut.hex", q1_lut);
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
    //   p2[13:0]  fc    UQ4.10     p2[27:14] resonance UQ4.10 log2
    //             (r octaves of Q above Butterworth; q1 = sqrt2*2^-r,
    //              decoded via q1_lut like cutoff K; p2[31:28] reserved)
    //   p3[7:0]   volume L UQ4.4   p3[15:8] volume R UQ4.4
    //             (0x00 = silence/exact mute .. 0xFF = loudest;
    //              inverted to the attenuation code at the effective-
    //              parameter seam — issue #40)
    //   p3[16]    24 dB mode       p3[18:17] filter type
    //----------------------------------------------------------------
    // Doubled for ping-pong: {bank, voice} addressing, both halves
    // initialized to the boot image so an unwritten shadow is sane
    // (all-zeros would be 0 dB gains at pitch zero — NOT mute).
    reg [35:0] osc_param_ram [0:2*NUM_ELEMENTS-1];
    reg [35:0] duty_param_ram [0:2*NUM_ELEMENTS-1];
    reg [35:0] filter_param_ram [0:2*NUM_ELEMENTS-1];
    reg [35:0] gain_param_ram [0:2*NUM_ELEMENTS-1];

    // Pointer words: per-element bus pointers, three 10-bit fields
    // each. +5 (PTRS0): [9:0] pitch, [19:10] duty, [29:20] cutoff.
    // +6 (PTRS1): [9:0] Q, [19:10] gain L, [29:20] gain R. Pointers
    // are wiring, so they ride the ping-pong banks like every
    // parameter. Init 0: every parameter points at bus 0 (hardwired
    // zero), so boot behavior is exactly the pre-bus behavior.
    reg [29:0] ptrs0_param_ram [0:2*NUM_ELEMENTS-1];
    reg [29:0] ptrs1_param_ram [0:2*NUM_ELEMENTS-1];
    integer pi;
    initial for (pi = 0; pi < 2*NUM_ELEMENTS; pi = pi + 1) begin
        ptrs0_param_ram[pi] = 30'd0;
        ptrs1_param_ram[pi] = 30'd0;
    end

    // GATE word (map offset +4): [0] gate, [1] retrig (reserved).
    // Gate 0 silences the element (gain decode forced to exact mute);
    // the oscillator and filters free-run regardless — later this
    // edge becomes the ADSR trigger. Both banks boot gated ON so the
    // boot image keeps sounding (the power-up liveness check).
    reg [1:0] gate_param_ram [0:2*NUM_ELEMENTS-1];
    integer gi;
    initial for (gi = 0; gi < 2*NUM_ELEMENTS; gi = gi + 1)
        gate_param_ram[gi] = 2'b01;

    initial begin
        $readmemh(P0_HEX, osc_param_ram, 0, NUM_ELEMENTS-1);
        $readmemh(P1_HEX, duty_param_ram, 0, NUM_ELEMENTS-1);
        $readmemh(P2_HEX, filter_param_ram, 0, NUM_ELEMENTS-1);
        $readmemh(P3_HEX, gain_param_ram, 0, NUM_ELEMENTS-1);
        $readmemh(P0_HEX, osc_param_ram, NUM_ELEMENTS, 2*NUM_ELEMENTS-1);
        $readmemh(P1_HEX, duty_param_ram, NUM_ELEMENTS, 2*NUM_ELEMENTS-1);
        $readmemh(P2_HEX, filter_param_ram, NUM_ELEMENTS, 2*NUM_ELEMENTS-1);
        $readmemh(P3_HEX, gain_param_ram, NUM_ELEMENTS, 2*NUM_ELEMENTS-1);
    end

    //----------------------------------------------------------------
    // Bank control: active half (sysclk) flips at drum slot 512 when a
    // swap is pending; the sclk write side steers by a synced
    // complement of the active bank (memory map wording, literally).
    //----------------------------------------------------------------
    logic bank_active;
    logic swap_toggle_meta, swap_toggle_sync, swap_toggle_prev;          // swap_req toggle sync (sysclk)
    logic swap_pending;

    initial begin
        bank_active  = 1'b0;
        {swap_toggle_meta, swap_toggle_sync, swap_toggle_prev} = '0;
        swap_pending = 1'b0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_active  <= 1'b0;
            swap_toggle_meta <= 1'b0; swap_toggle_sync <= 1'b0; swap_toggle_prev <= 1'b0;
            swap_pending <= 1'b0;
        end else begin
            swap_toggle_meta <= swap_req;
            swap_toggle_sync <= swap_toggle_meta;
            swap_toggle_prev <= swap_toggle_sync;
            if (swap_toggle_sync != swap_toggle_prev)
                swap_pending <= 1'b1;
            else if (swap_pending && slot == synth_pkg::SWAP_SLOT[9:0]) begin
                bank_active  <= ~bank_active;
                swap_pending <= 1'b0;
            end
        end
    end

    // write side: shadow = complement of active, synced into sclk
    logic bank_active_meta, bank_active_sync;
    initial {bank_active_meta, bank_active_sync} = '0;
    always_ff @(posedge sclk) begin
        bank_active_meta <= bank_active;
        bank_active_sync <= bank_active_meta;
    end
    wire bank_shadow = ~bank_active_sync;

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
    logic               walker_bus_write;
    logic [9:0]         walker_bus_addr;
    logic signed [17:0] walker_bus_value;

    logic bus_write_toggle_meta, bus_write_toggle_sync, bus_write_toggle_prev;
    logic bus_mailbox_pending;
    logic [9:0]  bus_mailbox_addr;
    logic [17:0] bus_mailbox_data;
    // Mailbox commits happen in any idle slot where the walker is not
    // writing the replicas THIS cycle (walker_bus_write below): lane reads issue
    // during slots 1..~257, and a commit colliding with a walker
    // write simply defers one cycle. The window stays ~500 slots
    // wide, so a 10 MHz SPI burst can never overrun the 1-deep
    // mailbox (word period 5.6 us >> max wait).
    // bus_mailbox_take is the SINGLE condition for both committing and
    // clearing pending. An earlier version cleared pending on
    // bus_write_window alone while the commit also required !walker_bus_write — when a
    // write's first idle cycle coincided with a walker write (~1 in
    // 3 during the walker span), the write was silently dropped:
    // a lost gate-off was a stuck note, a lost gate-on a dead key.
    wire  bus_write_window   = (slot > 10'd258) && (slot < 10'd760);
    wire  bus_mailbox_take   = bus_mailbox_pending && bus_write_window && !walker_bus_write;
    wire  bus_commit = bus_mailbox_take && (bus_mailbox_addr != 10'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_write_toggle_meta <= 1'b0; bus_write_toggle_sync <= 1'b0; bus_write_toggle_prev <= 1'b0;
            bus_mailbox_pending <= 1'b0;
            bus_mailbox_addr <= '0; bus_mailbox_data <= '0;
        end else begin
            bus_write_toggle_meta <= bus_write_toggle; bus_write_toggle_sync <= bus_write_toggle_meta; bus_write_toggle_prev <= bus_write_toggle_sync;
            if (bus_write_toggle_sync != bus_write_toggle_prev) begin
                bus_mailbox_pending <= 1'b1;         // payload is stable: it was
                bus_mailbox_addr   <= bus_write_addr;      // written before the toggle,
                bus_mailbox_data   <= bus_write_data;      // 2 sync FFs ago
            end else if (bus_mailbox_take) begin
                bus_mailbox_pending <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk)
        if (bus_commit) bus_base[bus_mailbox_addr] <= $signed(bus_mailbox_data);

    // Replica writes: one physical port, two writers — the walker
    // owns its cycle (walker_bus_write), the mailbox defers around it.
    always_ff @(posedge clk)
        if (bus_commit)   bus_ram_pitch[bus_mailbox_addr] <= $signed(bus_mailbox_data);
        else if (walker_bus_write)   bus_ram_pitch[walker_bus_addr]   <= walker_bus_value;
    always_ff @(posedge clk)
        if (bus_commit)   bus_ram_duty[bus_mailbox_addr] <= $signed(bus_mailbox_data);
        else if (walker_bus_write)   bus_ram_duty[walker_bus_addr]   <= walker_bus_value;
    always_ff @(posedge clk)
        if (bus_commit)   bus_ram_fc[bus_mailbox_addr] <= $signed(bus_mailbox_data);
        else if (walker_bus_write)   bus_ram_fc[walker_bus_addr]   <= walker_bus_value;
    always_ff @(posedge clk)
        if (bus_commit)   bus_ram_q[bus_mailbox_addr] <= $signed(bus_mailbox_data);
        else if (walker_bus_write)   bus_ram_q[walker_bus_addr]   <= walker_bus_value;
    always_ff @(posedge clk)
        if (bus_commit)   bus_ram_gl[bus_mailbox_addr] <= $signed(bus_mailbox_data);
        else if (walker_bus_write)   bus_ram_gl[walker_bus_addr]   <= walker_bus_value;
    always_ff @(posedge clk)
        if (bus_commit)   bus_ram_gr[bus_mailbox_addr] <= $signed(bus_mailbox_data);
        else if (walker_bus_write)   bus_ram_gr[walker_bus_addr]   <= walker_bus_value;

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
    //   P2: REGISTER rate decode + gate + source (each a short
    //       RAM-output cone); read DEPTH
    //   P3: state step from registers (adds/compares) + writeback;
    //       source × depth (DSP, registered operands — a parallel,
    //       independent path); read target base (bus_base — port
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

    reg [35:0] producer_table_ram [0:8*synth_pkg::NUM_PRODUCERS-1]; // {bank,entry,word[1:0]}
    // State word: LFO uses [23:0] as its phase; ADSR uses [27:26] as
    // the stage and [25:0] as the level in UQ22.4 — FOUR FRACTIONAL
    // BITS, so rate increments are in 1/16-LSB units and the 8-bit
    // log2 rate byte decodes as ONE uniform expression with no
    // truncation anywhere: all 256 codes are distinct equal-ratio
    // steps (Thor's perceptual-linearity rule; a MIDI CC maps as
    // cc << 1). The fractional bits ARE the "binary point moved four
    // left" — in the accumulator, where it belongs.
    reg [27:0] producer_state_ram [0:synth_pkg::NUM_PRODUCERS-1];
    integer wi;
    initial begin
        for (wi = 0; wi < 8*synth_pkg::NUM_PRODUCERS; wi = wi + 1)
            producer_table_ram[wi] = 36'd0;                  // type 0 = off
        for (wi = 0; wi < synth_pkg::NUM_PRODUCERS; wi = wi + 1)
            producer_state_ram[wi] = 28'd0;
    end

    always_ff @(posedge sclk)
        if (producer_write_enable) producer_table_ram[{bank_shadow, producer_write_addr}] <= {4'b0, producer_write_data};

    // control: 3-slot stride via a small counter, armed at slot 299
    logic [1:0] walker_step;
    logic [7:0] walker_entry;
    wire walker_active = (walker_entry < 8'(synth_pkg::NUM_PRODUCERS));
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            walker_step <= 2'd0; walker_entry <= 8'hFF;
        end else if (slot == 10'd299) begin
            walker_step <= 2'd0; walker_entry <= 8'd0;
        end else if (walker_active) begin
            if (walker_step == 2'd2) begin
                walker_step <= 2'd0;
                walker_entry <= walker_entry + 8'd1;
            end else
                walker_step <= walker_step + 2'd1;
        end
    end
    wire walker_entry_start = walker_active && (walker_step == 2'd0);

    // Sequential read registers: producer_table_ram serves CFG/RATES/DEPTH on
    // consecutive cycles through ONE register (address muxed by
    // phase); bus_base serves the gate read (P1) and the target-base
    // read (P3) through one register the same way.
    logic [35:0] producer_table_readout;
    logic [27:0] producer_state_readout;
    logic signed [17:0] bus_base_readout;
    logic        walker_read_valid; // a P0 read was issued last cycle

    // A stage — latched at the end of P1, stable for 3 cycles
    logic        producer_valid_a;
    logic [6:0]  producer_index_a;
    logic [3:0]  producer_type_a;
    logic [1:0]  lfo_shape_a;
    logic [9:0]  target_bus_a;
    logic [15:0] lfo_rate_a;
    logic [27:0] producer_state_prev;
    // B stage — latched at the end of P2
    logic        producer_valid_b;
    logic [9:0]  target_bus_b;
    logic signed [17:0] mod_source_value;
    // C stage — latched at the end of P3
    logic        producer_valid_c;
    logic [9:0]  target_bus_c;
    logic signed [35:0] depth_product;
    // E stage — the saturated sum, latched at the end of P4
    logic        walker_write_valid;
    logic [9:0]  walker_write_bus;
    logic signed [17:0] walker_write_value;

    // LFO waveform on the OLD phase (registered producer_state_prev → rule-clean).
    // Named intermediate wire: a $signed() cast directly in the port
    // connection crashes yosys's genrtlil signedness assert.
    wire signed [23:0] walker_lfo_phase = $signed(producer_state_prev[23:0]);
    logic signed [17:0] walker_lfo_wave;
    osc_core u_wk_osc (
        .phase      (walker_lfo_phase),
        .delta      (24'sd0),
        .duty       (24'sd0),
        .wave       (lfo_shape_a),
        .phase_next (),
        .sample_out (walker_lfo_wave)
    );

    // Rate decode + gate, REGISTERED at P2 (each cone is one RAM
    // output through shifts or a compare — short); the state step
    // then runs at P3 entirely from registers. This split exists
    // because the un-split version made the RAM-output→state-write
    // cone the critical path (76 MHz — 3.5% margin, on a timing
    // model proven optimistic five times).
    logic        adsr_gate;
    logic [20:0] adsr_attack_step, adswap_toggle_prevecay_step, adsr_release_step;   // 1/16-LSB units
    logic [25:0] adswap_toggle_syncustain_target;

    // next-state, computed at P3 from registered inputs only.
    // ADSR level is UQ22.4 (26 bits).
    wire [1:0]  adswap_toggle_synctage_prev  = producer_state_prev[27:26];
    wire [25:0] adsr_level_prev  = producer_state_prev[25:0];
    logic [27:0] producer_state_next;
    always_comb begin
        if (producer_type_a == 4'd1) begin
            // LFO: free-running phase accumulator in [23:0]
            producer_state_next = {producer_state_prev[27:24], producer_state_prev[23:0] + {8'b0, lfo_rate_a}};
        end else if (!adsr_gate) begin
            // ADSR, gate low: release toward zero
            producer_state_next = (adsr_level_prev > {5'b0, adsr_release_step})
                ? {AST_REL, adsr_level_prev - 26'(adsr_release_step)}
                : {AST_IDLE, 26'd0};
        end else begin
            case (adswap_toggle_synctage_prev)
                AST_ATT: producer_state_next =
                    ({1'b0, adsr_level_prev} + 27'(adsr_attack_step) > 27'h3FFFFFF)
                        ? {AST_DEC, 26'h3FFFFFF}
                        : {AST_ATT, adsr_level_prev + 26'(adsr_attack_step)};
                AST_DEC: producer_state_next =
                    (adsr_level_prev > adswap_toggle_syncustain_target + 26'(adswap_toggle_prevecay_step))
                        ? {AST_DEC, adsr_level_prev - 26'(adswap_toggle_prevecay_step)}
                        : (adsr_level_prev > adswap_toggle_syncustain_target) ? {AST_DEC, adswap_toggle_syncustain_target}
                                             : {AST_DEC, adsr_level_prev};
                default: producer_state_next = {AST_ATT, adsr_level_prev};  // idle/release
            endcase
        end
    end

    // P4 (walker_step == 1) combinational: value = base + contribution,
    // saturating — REGISTERED into walker_write_* at the end of P4, written to
    // the replicas at P5 (walker_step == 2). The RAM-output → add → clamp →
    // RAM-write chain carries a register in the middle (the 76 MHz
    // critical-path fix). Declared before the stage block below
    // (iverilog binds declaration-before-use at module scope).
    wire signed [19:0] walker_contribution = depth_product[35:16];
    wire signed [20:0] walker_sum =
        {{3{bus_base_readout[17]}}, bus_base_readout} + {walker_contribution[19], walker_contribution};
    wire signed [17:0] walker_value_clamped =
        (walker_sum > 21'sd131071)  ? 18'sd131071  :
        (walker_sum < -21'sd131072) ? -18'sd131072 : walker_sum[17:0];

    // Phase-guarded stage latches: each stage latches only at its own
    // phase edge and stays stable for the entry's three cycles.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            walker_read_valid <= 1'b0;
            producer_valid_a <= 1'b0; producer_valid_b <= 1'b0; producer_valid_c <= 1'b0; walker_write_valid <= 1'b0;
            producer_index_a <= '0; producer_type_a <= '0; lfo_shape_a <= '0;
            target_bus_a <= '0; lfo_rate_a <= '0; producer_state_prev <= '0;
            target_bus_b <= '0; mod_source_value <= '0;
            target_bus_c <= '0; depth_product <= '0;
            walker_write_bus <= '0; walker_write_value <= '0;
            adsr_gate <= 1'b0;
            adsr_attack_step <= '0; adswap_toggle_prevecay_step <= '0; adsr_release_step <= '0; adswap_toggle_syncustain_target <= '0;
        end else begin
            walker_read_valid <= walker_entry_start;

            if (walker_step == 2'd1) begin
                // end of P1: latch config (producer_table_readout = CFG) + state
                producer_valid_a     <= walker_read_valid;
                producer_index_a     <= walker_entry[6:0];
                producer_type_a  <= producer_table_readout[3:0];
                lfo_shape_a <= producer_table_readout[5:4];
                target_bus_a   <= producer_table_readout[15:6];
                lfo_rate_a  <= producer_table_readout[31:16];
                producer_state_prev      <= producer_state_readout;
                // ...and register the previous entry's saturated sum
                // (write happens next cycle, at P5)
                walker_write_valid   <= producer_valid_c && (target_bus_c != 10'd0);
                walker_write_bus <= target_bus_c;
                walker_write_value <= walker_value_clamped;
                producer_valid_c    <= 1'b0;
            end else if (walker_step == 2'd2) begin
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
                adsr_gate <= (bus_base_readout > 18'sd0);
                adsr_attack_step <= (21'd16 + 21'(producer_table_readout[3:0]))
                               << producer_table_readout[7:4];
                adswap_toggle_prevecay_step <= (21'd16 + 21'(producer_table_readout[11:8]))
                               << producer_table_readout[15:12];
                adswap_toggle_syncustain_target  <= {producer_table_readout[23:16], 18'b0};
                adsr_release_step <= (21'd16 + 21'(producer_table_readout[27:24]))
                               << producer_table_readout[31:28];
                producer_valid_b   <= producer_valid_a && (producer_type_a == 4'd1 || producer_type_a == 4'd2);
                target_bus_b <= target_bus_a;
                mod_source_value   <= (producer_type_a == 4'd1) ? walker_lfo_wave
                                            : $signed({2'b0, producer_state_prev[25:10]});
                walker_write_valid  <= 1'b0;              // P5 write just happened
            end else begin
                // end of P3 (walker_step == 0): the producer multiply —
                // registered operands (mod_source_value, and producer_table_readout = DEPTH);
                // state writeback happens here too (see below)
                producer_valid_c   <= producer_valid_b;
                target_bus_c <= target_bus_b;
                depth_product     <= mod_source_value * $signed(producer_table_readout[17:0]);
                producer_valid_b   <= 1'b0;
                producer_valid_a   <= 1'b0;
            end
        end
    end

    assign walker_bus_value = walker_write_value;
    assign walker_bus_addr = walker_write_bus;
    assign walker_bus_write  = walker_write_valid && (walker_step == 2'd2);

    // walker memory reads — sync-only, one register per RAM, address
    // muxed by phase: producer_table_ram serves CFG (P0) / RATES (P1) /
    // DEPTH (P2); bus_base serves the gate bus (P1, address from the
    // CFG word just read) / the target base (P3).
    always_ff @(posedge clk) begin
        producer_table_readout  <= producer_table_ram[{bank_active, walker_entry[6:0], walker_step}];
        producer_state_readout    <= producer_state_ram[walker_entry[6:0]];
        bus_base_readout <= bus_base[(walker_step == 2'd1) ? producer_table_readout[25:16]
                                              : target_bus_b];
    end
    always_ff @(posedge clk)
        if ((walker_step == 2'd0) && producer_valid_a
            && (producer_type_a == 4'd1 || producer_type_a == 4'd2))
            producer_state_ram[producer_index_a] <= producer_state_next;                      // P3

    //----------------------------------------------------------------
    // S0/S1 — RAM reads (address = element entering this cycle)
    //
    // Sync-only process: yosys memory inference (BSRAM read port).
    // Read data validity is gated by s1_act, so no reset is needed.
    //----------------------------------------------------------------
    logic [VW-1:0] elem_read_index;
    assign elem_read_index = lane_enter ? slot[VW-1:0] : '0;

    logic        s1_act;
    logic [VW-1:0] s1_idx;
    logic [13:0] s1_pitch;
    logic [1:0]  s1_wave;
    logic signed [23:0] s1_duty;
    logic [13:0] s1_fc;
    logic [13:0] s1_reso;   // log2 resonance code (UQ4.10)
    logic [7:0]  s1_gl, s1_gr;
    logic        s1_dual;
    logic [1:0]  s1_ftype;
    logic signed [23:0] s1_phase;
    logic signed [35:0] s1_ic1eq1, s1_ic2eq1, s1_ic1eq2, s1_ic2eq2;

    // Param RAM reads are SYNCHRONOUS on clk (was a comb read into the
    // same registers — identical timing, but sync-read + separate-clock
    // write is the shape yosys infers as dual-clock BSRAM). Sync-only
    // process, per the AGENTS.md inference gotcha; validity is act-gated.
    logic [35:0] s1_osc_word, s1_duty_word, s1_filter_word, s1_gain_word;
    logic [1:0]  s1_gate_word;
    logic [29:0] s1_ptrs0_word, s1_ptrs1_word;
    always_ff @(posedge clk) begin
        s1_osc_word     <= osc_param_ram[{bank_active, elem_read_index}];
        s1_duty_word     <= duty_param_ram[{bank_active, elem_read_index}];
        s1_filter_word     <= filter_param_ram[{bank_active, elem_read_index}];
        s1_gain_word     <= gain_param_ram[{bank_active, elem_read_index}];
        s1_gate_word     <= gate_param_ram[{bank_active, elem_read_index}];
        s1_ptrs0_word     <= ptrs0_param_ram[{bank_active, elem_read_index}];
        s1_ptrs1_word     <= ptrs1_param_ram[{bank_active, elem_read_index}];
        s1_phase  <= phase_ram[elem_read_index];
        s1_ic1eq1 <= ic1eq1_ram[elem_read_index];
        s1_ic2eq1 <= ic2eq1_ram[elem_read_index];
        s1_ic1eq2 <= ic1eq2_ram[elem_read_index];
        s1_ic2eq2 <= ic2eq2_ram[elem_read_index];
    end

    // SPI-side write ports (sclk domain) — sync-only, one per bank
    always_ff @(posedge sclk)
        if (elem_write_enable && elem_write_word == 3'd0) osc_param_ram[{bank_shadow, elem_write_index}] <= {4'b0, elem_write_data};
    always_ff @(posedge sclk)
        if (elem_write_enable && elem_write_word == 3'd1) duty_param_ram[{bank_shadow, elem_write_index}] <= {4'b0, elem_write_data};
    always_ff @(posedge sclk)
        if (elem_write_enable && elem_write_word == 3'd2) filter_param_ram[{bank_shadow, elem_write_index}] <= {4'b0, elem_write_data};
    always_ff @(posedge sclk)
        if (elem_write_enable && elem_write_word == 3'd3) gain_param_ram[{bank_shadow, elem_write_index}] <= {4'b0, elem_write_data};
    always_ff @(posedge sclk)
        if (elem_write_enable && elem_write_word == 3'd4) gate_param_ram[{bank_shadow, elem_write_index}] <= elem_write_data[1:0];
    always_ff @(posedge sclk)
        if (elem_write_enable && elem_write_word == 3'd5) ptrs0_param_ram[{bank_shadow, elem_write_index}] <= elem_write_data[29:0];
    always_ff @(posedge sclk)
        if (elem_write_enable && elem_write_word == 3'd6) ptrs1_param_ram[{bank_shadow, elem_write_index}] <= elem_write_data[29:0];

    // field views of the registered param words
    assign s1_pitch = s1_osc_word[13:0];
    assign s1_wave  = s1_osc_word[15:14];
    assign s1_duty  = s1_duty_word[23:0];
    assign s1_fc    = s1_filter_word[13:0];
    assign s1_reso  = s1_filter_word[27:14];
    // GAIN word carries VOLUME (issue #40, 0x00 = silence .. 0xFF =
    // loudest): a zeroed parameter word is now silent-by-default
    // instead of full-blast. GATE off = volume zero, which the
    // effective-parameter stage maps onto the existing exact-mute
    // machinery:
    // one decode-stage mux, no new carry registers down the pipeline.
    assign s1_gl    = s1_gate_word[0] ? s1_gain_word[7:0]  : 8'h00;
    assign s1_gr    = s1_gate_word[0] ? s1_gain_word[15:8] : 8'h00;
    assign s1_dual  = s1_gain_word[16];
    assign s1_ftype = s1_gain_word[18:17];

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
    logic [13:0] s2_reso;
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
        s2_bus_pitch <= bus_ram_pitch[s1_ptrs0_word[9:0]];
        s2_bus_duty  <= bus_ram_duty[s1_ptrs0_word[19:10]];
        s2_bus_fc    <= bus_ram_fc[s1_ptrs0_word[29:20]];
        s2_bus_q     <= bus_ram_q[s1_ptrs1_word[9:0]];
        s2_bus_gl    <= bus_ram_gl[s1_ptrs1_word[19:10]];
        s2_bus_gr    <= bus_ram_gr[s1_ptrs1_word[29:20]];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_act   <= 1'b0;
            s2_idx   <= '0;
            s2_pitch <= '0;
            s2_wave  <= '0;
            s2_duty  <= '0;
            s2_fc    <= '0;
            s2_reso  <= '0;
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
            s2_reso  <= s1_reso;
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
    //   pitch/cutoff/resonance: as-is (one bus integer = one octave;
    //          for resonance that is one octave of Q ≈ +6 dB of peak)
    //   duty:  <<< 13 (bus ±1.0 → duty ±1.0 in Q0.24)
    //   gains: >>> 6  (bus 1 octave = 6 dB = 16 UQ4.4 steps; positive
    //          bus = LOUDER — volume semantics, issue #40). A base of
    //          0x00 (exact mute — hard-panned channels, gated
    //          elements) is preserved regardless of the bus, and the
    //          bus alone can never reach exact mute (sums clamp to
    //          the quietest audible step). The sum is converted to
    //          the attenuation code here, at ONE seam, so everything
    //          downstream (S9B decode, mute == 0xFF) is untouched.
    //----------------------------------------------------------------
    // Resonance is log2-encoded (Thor, 2026-09-02: "break with
    // convention"): r = octaves of Q above Butterworth, UQ4.10;
    // q1 = sqrt(2) * 2^-r via q1_lut + barrel shift, the same decode
    // shape as cutoff K. The old [0, sqrt2] damping clamp is now
    // STRUCTURAL: r = 0 IS Butterworth and nothing decodes heavier;
    // at the top of the range the shift underflows q1 toward zero,
    // so self-oscillation is the natural top of scale — reachable as
    // a feature, no special code.
    wire signed [18:0] reso_sum =
        $signed({5'b0, s2_reso}) + {s2_bus_q[17], s2_bus_q};
    wire [13:0] eff_reso =
        reso_sum[18]            ? 14'd0    :
        (reso_sum > 19'sd16383) ? 14'h3FFF : reso_sum[13:0];

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
    // volume in, attenuation code out (the one subtract of issue #40)
    wire [7:0] eff_gl =
        (s2_gl == 8'h00)      ? 8'hFF :             // base mute wins
        (gl_sum[18] || gl_sum == 19'sd0)
                              ? 8'hFE :             // quietest audible
        (gl_sum > 19'sd255)   ? 8'h00 :             // full volume
        8'hFF - gl_sum[7:0];
    wire [7:0] eff_gr =
        (s2_gr == 8'h00)      ? 8'hFF :
        (gr_sum[18] || gr_sum == 19'sd0)
                              ? 8'hFE :
        (gr_sum > 19'sd255)   ? 8'h00 :
        8'hFF - gr_sum[7:0];

    //----------------------------------------------------------------
    // S3 — LUT data, delta/K, phase_next, oscillator waveform
    //----------------------------------------------------------------
    logic [23:0] s3_delta_lut;
    logic [15:0] s3_k_lut;
    logic [16:0] s3_q1_lut;
    logic [3:0]  s3_reso_oct;

    logic        s3_act;
    logic [VW-1:0] s3_idx;
    logic signed [23:0] s3_phase;
    logic [3:0]  s3_pitch_oct;
    logic [3:0]  s3_fc_oct;
    logic [1:0]  s3_wave;
    logic signed [23:0] s3_duty;
    logic [7:0]  s3_gl, s3_gr;
    logic        s3_dual;
    logic [1:0]  s3_ftype;
    logic signed [35:0] s3_ic1eq1, s3_ic2eq1, s3_ic1eq2, s3_ic2eq2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_delta_lut <= '0;
            s3_k_lut     <= '0;
            s3_q1_lut    <= '0;
            s3_reso_oct  <= '0;
            s3_act   <= 1'b0;
            s3_idx   <= '0;
            s3_phase <= '0;
            s3_pitch_oct <= '0;
            s3_fc_oct    <= '0;
            s3_wave  <= '0;
            s3_duty  <= '0;
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
            s3_q1_lut    <= q1_lut[eff_reso[9:6]];
            s3_reso_oct  <= eff_reso[13:10];
            s3_act   <= s2_act;
            s3_idx   <= s2_idx;
            s3_phase <= s2_phase;
            s3_pitch_oct <= eff_pitch[13:10];
            s3_fc_oct    <= eff_fc[13:10];
            s3_wave  <= s2_wave;
            s3_duty  <= eff_duty;
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
    // Resonance decode: q1 = sqrt(2) * 2^-r in Q2.16. Same
    // LUT+barrel-shift shape as K; registered into S3B before the
    // S4 multiply (the silicon timing rule). At high octaves the
    // shift underflows to 0 — self-oscillation, by design.
    wire signed [17:0] q1_decoded =
        $signed({1'b0, s3_q1_lut}) >>> s3_reso_oct;

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
            s3b_q1   <= q1_decoded;
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
