//--------------------------------------------------------------------
// element_pipeline.sv — 256-element SCMO pipeline (the drum's lanes)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
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
//   S3  LUT data → delta, K, q1; phase_next = phase + delta (ONE adder)
//   S3B register phase_next / barrel-shifted K / q1 / duty / wave
//   S3C oscillator waveform from the REGISTERED phase (sine LUT + mux)
//   S3D #43 resonance attenuation multiply on registered operands (DSP)
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
//   audio      Q4.14   (18-bit; repointed from Q2.16 in #63 — same
//              word, clamp ±8.0, +12 dB resonance headroom)
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

    // Instruction table writes (sclk domain, banked — wiring per law 4)
    input  logic           imem_write_enable,
    input  logic [9:0]     imem_write_addr,     // {entry[7:0], word[1:0]} (#100)
    input  logic [31:0]    imem_write_data,
    input  logic [7:0]     elem_write_index,
    input  logic [31:0]    elem_write_data,
    input  logic           swap_req,    // sclk-domain toggle

    output logic signed [23:0] mix_left,    // Q0.24, published 10 cycles
                                             // after sample_tick (S11
                                             // limiter, #121); stable by
                                             // the next tick, which is when
                                             // every consumer latches it
    output logic signed [23:0] mix_right,

    // Test-tone control (audio-chain purity check, issue #81): bus
    // address 1023 is reserved as a control latch — bit 0 enables the
    // top-level 187.5 Hz full-scale sine that replaces the mix at the
    // outputs. Latched here because the bus mailbox already has the
    // sclk→sysclk CDC; no pointer ever references bus 1023.
    output logic           test_tone_en
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
    reg [15:0] reso_att_lut [0:63];    // #43 resonance-indexed input
                                       // attenuation, UQ0.16 (dual)

    initial begin
        $readmemh("element/phase_lut.hex", phase_lut);
        $readmemh("element/svf_k_lut.hex", k_lut);
        $readmemh("element/q1_lut.hex", q1_lut);
        $readmemh("element/att_lut.hex", att_lut);
        $readmemh("element/reso_att_lut.hex", reso_att_lut);
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
    // the oscillator and filters free-run regardless. NOTE (Thor,
    // #98): this never became and will never become an ADSR trigger —
    // envelopes are sequencer SOURCES, gated by a control input (a gate
    // bus shared across a voice's elements), not element traits.
    // Today GATE's only job
    // is the exact-mute path (#68); Thor has proposed dropping GATE
    // and RETRIG as element parameters entirely (#98 discussion).
    // Both banks boot gated ON so the boot image keeps sounding (the
    // power-up liveness check).
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

    //----------------------------------------------------------------
    // The modulation bus and its source sequencer now live in their own
    // module (#136). Six read ports: S1 pointers in, S2 data out.
    //----------------------------------------------------------------
    logic signed [17:0] s2_bus_pitch, s2_bus_duty, s2_bus_fc;
    logic signed [17:0] s2_bus_q, s2_bus_gl, s2_bus_gr;

    csp u_csp (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick), .sclk(sclk),
        .bank_active(bank_active), .bank_shadow(bank_shadow),
        .bus_write_addr(bus_write_addr), .bus_write_data(bus_write_data),
        .bus_write_toggle(bus_write_toggle),
        .imem_write_enable(imem_write_enable),
        .imem_write_addr(imem_write_addr),
        .imem_write_data(imem_write_data),
        .rd_pitch_a(s1_ptrs0_word[8:0]),
        .rd_duty_a (s1_ptrs0_word[18:10]),
        .rd_fc_a   (s1_ptrs0_word[28:20]),
        .rd_q_a    (s1_ptrs1_word[8:0]),
        .rd_gl_a   (s1_ptrs1_word[18:10]),
        .rd_gr_a   (s1_ptrs1_word[28:20]),
        .rd_pitch_d(s2_bus_pitch), .rd_duty_d(s2_bus_duty), .rd_fc_d(s2_bus_fc),
        .rd_q_d(s2_bus_q), .rd_gl_d(s2_bus_gl), .rd_gr_d(s2_bus_gr),
        .test_tone_en(test_tone_en)
    );


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
    logic [15:0] s3_reso_att;   // #43 input-atten gain (UQ0.16)
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
            s3_reso_att <= 16'hffff;
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
            s3_reso_att <= s2_dual ? reso_att_lut[eff_reso[13:8]] : 16'hffff;
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

    // #128: the phase advance is ONE adder now, here, and its result is
    // REGISTERED (s3b_phase) before any waveform is generated from it.
    // It used to be computed twice -- once inside osc_core feeding the
    // waveforms, once again below for the writeback -- and the waveform
    // path hung off the combinational sum, giving one cycle of
    // BSRAM read -> octave shift -> 24-bit add -> sine LUT -> mux.
    // That was the critical path of the whole design.
    wire signed [23:0] phase_next = s3_phase + delta;

    //----------------------------------------------------------------
    // S3B/S3C -- resonance-dependent INPUT attenuation (#43). Scale the
    // oscillator sample down as resonance rises so the 24 dB/oct dual
    // cascade never overdrives its internal +-8 guardrail (sat_q414).
    // Register-then-multiply: S3B registers osc + the (dual-gated) atten
    // and every SVF operand; S3C multiplies. Keeps the osc_core->reg
    // critical path intact (no combinational mult in it). Single (12
    // dB/oct) never overdrives, so its atten is unity (0xffff).
    //----------------------------------------------------------------
    // S3B registers the ADVANCED PHASE (and duty/wave alongside it); the
    // waveform is generated from the registered value in S3B->S3C (#128).
    logic               s3b_act;   logic [VW-1:0] s3b_idx;
    logic [15:0] s3b_att;
    logic signed [35:0] s3b_k;     logic signed [17:0] s3b_q1;
    logic signed [35:0] s3b_ic1eq1, s3b_ic2eq1, s3b_ic1eq2, s3b_ic2eq2;
    logic               s3b_dual;  logic [1:0] s3b_ftype;
    logic signed [23:0] s3b_phase; logic [7:0] s3b_gl, s3b_gr;
    logic signed [23:0] s3b_duty;  logic [1:0] s3b_wave;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3b_act<=1'b0; s3b_idx<='0; s3b_att<='0;
            s3b_k<='0; s3b_q1<='0; s3b_ic1eq1<='0; s3b_ic2eq1<='0;
            s3b_ic1eq2<='0; s3b_ic2eq2<='0; s3b_dual<=1'b0; s3b_ftype<='0;
            s3b_phase<='0; s3b_gl<='0; s3b_gr<='0;
            s3b_duty<='0; s3b_wave<='0;
        end else begin
            s3b_act<=s3_act; s3b_idx<=s3_idx;
            s3b_att<=s3_reso_att; s3b_k<=k; s3b_q1<=q1_decoded;
            s3b_ic1eq1<=s3_ic1eq1; s3b_ic2eq1<=s3_ic2eq1;
            s3b_ic1eq2<=s3_ic1eq2; s3b_ic2eq2<=s3_ic2eq2;
            s3b_dual<=s3_dual; s3b_ftype<=s3_ftype;
            s3b_phase<=phase_next; s3b_gl<=s3_gl; s3b_gr<=s3_gr;
            s3b_duty<=s3_duty; s3b_wave<=s3_wave;
        end
    end

    // Waveform generation now stands alone in its own stage, driven by
    // the REGISTERED phase. This is the half of the old critical path
    // that was chained behind the adder: sine LUT read + 4:1 mux (#128).
    osc_core u_osc (
        .phase_next (s3b_phase),
        .duty       (s3b_duty),
        .wave       (s3b_wave),
        .sample_out (osc_sample)
    );

    // S3C registers the WAVEFORM (was: the attenuation product). The
    // multiply moves to S3D so nothing chains a mux into a DSP.
    logic               s3c_act;   logic [VW-1:0] s3c_idx;
    logic signed [17:0] s3c_osc;   logic [15:0] s3c_att;
    logic signed [35:0] s3c_k;     logic signed [17:0] s3c_q1;
    logic signed [35:0] s3c_ic1eq1, s3c_ic2eq1, s3c_ic1eq2, s3c_ic2eq2;
    logic               s3c_dual;  logic [1:0] s3c_ftype;
    logic signed [23:0] s3c_phase; logic [7:0] s3c_gl, s3c_gr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3c_act<=1'b0; s3c_idx<='0; s3c_osc<='0; s3c_att<='0;
            s3c_k<='0; s3c_q1<='0;
            s3c_ic1eq1<='0; s3c_ic2eq1<='0; s3c_ic1eq2<='0; s3c_ic2eq2<='0;
            s3c_dual<=1'b0; s3c_ftype<='0; s3c_phase<='0; s3c_gl<='0; s3c_gr<='0;
        end else begin
            s3c_act<=s3b_act; s3c_idx<=s3b_idx;
            s3c_osc <= osc_sample; s3c_att <= s3b_att;
            s3c_k<=s3b_k; s3c_q1<=s3b_q1;
            s3c_ic1eq1<=s3b_ic1eq1; s3c_ic2eq1<=s3b_ic2eq1;
            s3c_ic1eq2<=s3b_ic1eq2; s3c_ic2eq2<=s3b_ic2eq2;
            s3c_dual<=s3b_dual; s3c_ftype<=s3b_ftype;
            s3c_phase<=s3b_phase; s3c_gl<=s3b_gl; s3c_gr<=s3b_gr;
        end
    end

    //----------------------------------------------------------------
    // S3D -- the #43 attenuation multiply, on REGISTERED operands.
    // It used to sit at S3C; the waveform stage inserted by #128 pushed
    // it one stage later so that no cycle chains the waveform mux into
    // a DSP. Element latency is therefore 17 -> 18; the state writeback
    // lands 14 cycles after the read, against a 256-slot half, so read
    // and write still cannot collide.
    //----------------------------------------------------------------
    wire signed [35:0] osc_mul = s3c_osc * $signed({1'b0, s3c_att});
    logic               s3d_act;   logic [VW-1:0] s3d_idx;
    logic signed [17:0] s3d_osc;
    logic signed [35:0] s3d_k;     logic signed [17:0] s3d_q1;
    logic signed [35:0] s3d_ic1eq1, s3d_ic2eq1, s3d_ic1eq2, s3d_ic2eq2;
    logic               s3d_dual;  logic [1:0] s3d_ftype;
    logic signed [23:0] s3d_phase; logic [7:0] s3d_gl, s3d_gr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3d_act<=1'b0; s3d_idx<='0; s3d_osc<='0; s3d_k<='0; s3d_q1<='0;
            s3d_ic1eq1<='0; s3d_ic2eq1<='0; s3d_ic1eq2<='0; s3d_ic2eq2<='0;
            s3d_dual<=1'b0; s3d_ftype<='0; s3d_phase<='0; s3d_gl<='0; s3d_gr<='0;
        end else begin
            s3d_act<=s3c_act; s3d_idx<=s3c_idx;
            s3d_osc <= 18'($signed(osc_mul >>> 16));
            s3d_k<=s3c_k; s3d_q1<=s3c_q1;
            s3d_ic1eq1<=s3c_ic1eq1; s3d_ic2eq1<=s3c_ic2eq1;
            s3d_ic1eq2<=s3c_ic1eq2; s3d_ic2eq2<=s3c_ic2eq2;
            s3d_dual<=s3c_dual; s3d_ftype<=s3c_ftype;
            s3d_phase<=s3c_phase; s3d_gl<=s3c_gl; s3d_gr<=s3c_gr;
        end
    end

    //----------------------------------------------------------------
    // SVF core (TPT, #117/#118) -- replaces the Chamberlin S3B..S9.
    //   g = k>>1 (= pi*fc/fs), R2 = q1, h = 1/D via reciprocal LUT.
    //   Unconditionally stable under cutoff-modulation-at-resonance.
    //   Streaming, latency 17; states/phase/gains carried through.
    //   See rtl/element/svf_tpt.sv.
    //----------------------------------------------------------------
    wire               s9_act;
    wire [VW-1:0]      s9_idx;
    wire signed [17:0] s9_elem;
    wire signed [23:0] s9_phase;
    wire signed [35:0] s9_ic1eq1n, s9_ic2eq1n, s9_ic1eq2n, s9_ic2eq2n;
    wire [7:0]         s9_gl, s9_gr;

    svf_tpt #(.IDXW(VW)) u_svf (
        .clk(clk), .rst_n(rst_n),
        .in_act(s3d_act), .in_idx(s3d_idx),
        .in_osc(s3d_osc), .in_k(s3d_k), .in_q1(s3d_q1),
        .in_ic1a(s3d_ic1eq1), .in_ic2a(s3d_ic2eq1),
        .in_ic1b(s3d_ic1eq2), .in_ic2b(s3d_ic2eq2),
        .in_dual(s3d_dual), .in_ftype(s3d_ftype),
        .in_phase(s3d_phase), .in_gl(s3d_gl), .in_gr(s3d_gr),
        .out_act(s9_act), .out_idx(s9_idx), .out_elem(s9_elem),
        .out_ic1an(s9_ic1eq1n), .out_ic2an(s9_ic2eq1n),
        .out_ic1bn(s9_ic1eq2n), .out_ic2bn(s9_ic2eq2n),
        .out_phase(s9_phase), .out_gl(s9_gl), .out_gr(s9_gr)
    );

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
    // Mixdown headroom: 256 elements × Q4.14 (±8.0) sums to ±2048 in a
    // 26-bit Q4.14 accumulator (12 integer bits, ±2048) — marginal by
    // design exactly as the Q2.16 era was (256 × ±2.0 vs ±512). The
    // output limiter (sat24) converts Q4.14 → Q0.24 (<< 10) and clips
    // only in the pathological all-aligned-at-the-rail case; overall
    // loudness is set by the per-element UQ4.4 gains and is IDENTICAL
    // to the Q2.16 era at zero resonance (repoint #63: −2 bits of
    // audio scale cancel the +2 bits of conversion shift).
    //----------------------------------------------------------------
    function automatic logic signed [23:0] sat24(input logic signed [35:0] x);
        if (x > 36'sd8388607)
            sat24 = 24'sd8388607;
        else if (x < -36'sd8388608)
            sat24 = -24'sd8388608;
        else
            sat24 = x[23:0];
    endfunction

    logic signed [25:0] mix_l_acc, mix_r_acc;   // Q4.14 audio + 8 guard bits

    //----------------------------------------------------------------
    // S11 master limiter (#121, deployment A): log-domain peak limiter
    // on the PRE-clip accumulators (attenuate before the clamp -- the
    // #43 lesson), stereo-linked on max(|L|,|R|), FEEDFORWARD (this
    // sample's level gates this sample), then sat24. Fully registered,
    // one operation class per stage (the silicon timing rule): the first
    // cut computed abs -> max -> lzc -> shift -> LUT -> adds -> LUT ->
    // shift in ONE cycle, passed STA, and sputtered at -63 dBFS on the
    // board (2026-09-18). 768 cycles of slack per sample, so the phase
    // walk is free:  p1 abs | p2 max -> level | p3..p7 limiter pipeline
    // settles (5 stages) | p8 latch gain_q + gain | p9 multiply | p10
    // sat24 publish. Every consumer latches mix_* at the NEXT tick, so
    // audio semantics are unchanged. lim_gain_q persists across samples
    // = the envelope. Constants from scripts/limiter_model.py: threshold
    // -1 dBFS, attack 12 dB/sample, release ~105 dB/s. sat24 stays
    // underneath as the guaranteed catch.
    //----------------------------------------------------------------
    localparam int          LIM_SUB       = 11;
    localparam logic [7:0]  LIM_THRESH    = 8'd192;
    localparam logic [17:0] LIM_ATTACK_Q  = 18'd256;
    localparam logic [17:0] LIM_RELEASE_Q = 18'd1;
    logic signed [25:0] lim_acc_l, lim_acc_r, lim_prod_l, lim_prod_r;
    logic        [25:0] lim_abs_l, lim_abs_r, lim_level;   // unsigned magnitudes
    logic        [17:0] lim_gain_q;                        // envelope state
    logic        [16:0] lim_gain;                          // UQ0.16 applied gain
    logic        [3:0]  lim_phase;
    wire         [17:0] lim_gain_q_next;
    wire         [16:0] lim_gain_lin;
    limiter #(.LEVEL_W(26), .SUB(LIM_SUB)) u_lim (
        .clk(clk), .rst_n(rst_n),
        .level      (lim_level),
        .gain_q_in  (lim_gain_q),
        .thresh_code(LIM_THRESH),
        .attack_q   (LIM_ATTACK_Q),
        .release_q  (LIM_RELEASE_Q),
        .gain_q_out (lim_gain_q_next),
        .gain_lin   (lim_gain_lin)
    );
    // 26-bit acc x UQ0.16 gain -> back to the acc scale (>>16); gain <= 1
    // so it always fits. Registered-input, registered-output DSP.
    wire signed [43:0] lim_mul_l = lim_acc_l * $signed({1'b0, lim_gain});
    wire signed [43:0] lim_mul_r = lim_acc_r * $signed({1'b0, lim_gain});

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mix_l_acc  <= '0;
            mix_r_acc  <= '0;
            mix_left   <= '0;
            mix_right  <= '0;
            lim_acc_l  <= '0;
            lim_acc_r  <= '0;
            lim_abs_l  <= '0;
            lim_abs_r  <= '0;
            lim_level  <= '0;
            lim_prod_l <= '0;
            lim_prod_r <= '0;
            lim_gain_q <= '0;
            lim_gain   <= 17'h10000;
            lim_phase  <= 4'd0;
        end else begin
            if (sample_tick) begin
                // sample boundary: hold the finished sum for the
                // limiter, start accumulating the next sample
                lim_acc_l  <= mix_l_acc;
                lim_acc_r  <= mix_r_acc;
                mix_l_acc  <= '0;
                mix_r_acc  <= '0;
                lim_phase  <= 4'd1;
            end else if (s10_act) begin
                mix_l_acc <= mix_l_acc + {{8{s10_outl[17]}}, s10_outl};
                mix_r_acc <= mix_r_acc + {{8{s10_outr[17]}}, s10_outr};
            end
            case (lim_phase)
                4'd1: begin   // |acc|: explicit two's-complement negate on the bits
                    lim_abs_l <= lim_acc_l[25] ? (~lim_acc_l + 26'd1) : lim_acc_l;
                    lim_abs_r <= lim_acc_r[25] ? (~lim_acc_r + 26'd1) : lim_acc_r;
                    lim_phase <= 4'd2;
                end
                4'd2: begin   // stereo link: the louder channel gates both
                    lim_level <= (lim_abs_l > lim_abs_r) ? lim_abs_l : lim_abs_r;
                    lim_phase <= 4'd3;
                end
                4'd3, 4'd4, 4'd5, 4'd6, 4'd7:   // limiter pipeline settles
                    lim_phase <= lim_phase + 4'd1;
                4'd8: begin   // both outputs valid (gain_q from p7, gain from p8)
                    lim_gain_q <= lim_gain_q_next;
                    lim_gain   <= lim_gain_lin;
                    lim_phase  <= 4'd9;
                end
                4'd9: begin   // apply the gain
                    lim_prod_l <= 26'(lim_mul_l >>> 16);
                    lim_prod_r <= 26'(lim_mul_r >>> 16);
                    lim_phase  <= 4'd10;
                end
                4'd10: begin  // Q4.14 -> Q0.24, rail
                    mix_left   <= sat24(36'(lim_prod_l) <<< 10);
                    mix_right  <= sat24(36'(lim_prod_r) <<< 10);
                    lim_phase  <= 4'd0;
                end
                default: ;
            endcase
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
