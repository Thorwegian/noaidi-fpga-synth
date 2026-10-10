//--------------------------------------------------------------------
// element_pipeline.sv — 256-element SCMO pipeline (the drum's lanes)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One element enters a lane every sysclk cycle for 256 cycles of
// each sample period (drum slot 0..255).  Every cycle, every stage
// processes a different element: stage Sk at drum slot t holds the
// element that entered at slot t-k.  The pipeline is 26 stages deep
// (s10_valid follows s1_valid by 24 cycles in tb_element_pipeline), so it
// occupies 256 + 26 - 1 = 281 contiguous slots (~37% of the 768-slot
// drum rotation).
//
// Stage map:
//   S0  state/param RAM read address issued
//   S1  state/param RAM read data available
//   S2  issue phase-increment + SVF-K LUT reads
//   S3  LUT data → phase_inc, K, q1; phase_next = phase + phase_inc (ONE adder)
//   S3B register phase_next / barrel-shifted K / q1 / duty / wave
//   S3C oscillator waveform from the REGISTERED phase (sine LUT + mux)
//   S3D resonance attenuation multiply on registered operands (DSP)
//   S4..S9  svf_tpt: 17 registered stages (1 input, 2 coefficient,
//       7 per 2-pole section); its output is the element output
//   S9B attenuation decode: lin gains via LUT + barrel shift
//   S10 attenuation multiply on registered operands      (DSP); its
//       output is accumulated into the mix and the state written back
//
// S3B/S3C/S3D/S9B exist because chaining adder trees or LUT+barrel-
// shift decodes into a DSP multiply in one cycle violated setup on
// real silicon at 98.304 MHz (audible corruption, clean at half
// clock) — paths nextpnr's approximate timing model passes. Rule: a
// stage is adds/decode-only or multiply-only, never both chained.
// S3B is the last of the class: when per-element fc gives consecutive
// lanes different K shift amounts, a chord screams in the left
// channel, because the glitched lane after a group boundary is a
// left-panned element. No known residual of this class remains.
//
// Number formats (design doc):
//   phase      UQ0.24  (24-bit)
//   audio      Q4.14   (18-bit; clamp ±8.0, which is +12 dB of
//              resonance headroom)
//   SVF states Q8.28   (36-bit)
//   pitch/fc   UQ4.10  (14-bit)
//   gain       UQ4.4   (8-bit, log: 6 dB int steps + 0.375 dB frac)
//
// State RAM is semi dual-port: read address is issued with the element
// entering at S0, writeback happens 25 cycles later — the read
// and write addresses can never collide.
//--------------------------------------------------------------------
`default_nettype none
module element_pipeline #(
    parameter int NUM_ELEMENTS = synth_pkg::NUM_ELEMENTS,
    // Boot parameter images. Synthesis uses the tree's generated
    // images; testbenches override with rtl/tb/ref_boot_* (committed
    // fixtures) so bench expectations never depend on bench-local
    // experiments in scripts/gen_boot_image.py.
    parameter P0_HEX = "dsp/boot_p0.hex",
    parameter P1_HEX = "dsp/boot_p1.hex",
    parameter P2_HEX = "dsp/boot_p2.hex",
    parameter P3_HEX = "dsp/boot_p3.hex"
) (
    input  logic           clk,
    input  logic           rst_n,

    input  logic [9:0]     slot,
    input  logic           slot_issue,
    input  logic           sample_tick,

    // Per-element parameter writes from the SPI control plane.
    // sclk-domain write port on the param RAMs; the pipeline reads on
    // clk (sysclk) — the dual-clock BSRAM is the CDC (design doc).
    //
    // PING-PONG (memory map decision 7): the banks are doubled —
    // reads always hit the ACTIVE half, writes always the SHADOW half,
    // so a read and a write can never collide on one address (the
    // click-on-sweep bug). swap_toggle (an sclk-domain toggle from
    // CTRL@0x0002) flips the active half at drum slot 512: the
    // pipeline is drained there (the span ends at slot 280), so every sample's
    // 256 elements read one consistent bank generation.
    input  logic           sclk,
    input  logic           elem_write_enable,
    input  logic [2:0]     elem_write_word,     // 0..6 = p0..p3, GATE, PTRS0, PTRS1

    // Bus-write mailbox from spi_bus (sclk-domain toggle + payload).
    // Synced here and committed to bus RAM only in an idle drum slot,
    // so a commit never collides with a lane's bus read.
    input  logic [9:0]     dmem_wr_addr,
    input  logic [17:0]    dmem_wr_data,
    input  logic           dmem_wr_toggle,

    // Instruction table writes (sclk domain, banked — wiring per law 4)
    input  logic           imem_write_enable,
    input  logic [9:0]     imem_write_addr,     // {entry[7:0], word[1:0]}
    input  logic [31:0]    imem_write_data,
    input  logic [7:0]     elem_write_index,
    input  logic [31:0]    elem_write_data,
    input  logic           swap_toggle,    // sclk-domain toggle

    output logic signed [23:0] mix_left,    // Q0.24, published 10 cycles
                                             // after sample_tick (S11
                                             // limiter); stable by
                                             // the next tick, which is when
                                             // every consumer latches it
    output logic signed [23:0] mix_right,

    // Test-tone control (audio-chain purity check): bus
    // address 1023 is reserved as a control latch — bit 0 enables the
    // top-level 1500 Hz full-scale sine that replaces the mix at the
    // outputs. Latched here because the bus mailbox already has the
    // sclk→sysclk CDC; no pointer ever references bus 1023.
    output logic           test_tone_en
);

    localparam int VW = $clog2(NUM_ELEMENTS);   // element index width

    //----------------------------------------------------------------
    // LUT ROMs (combinational reads)
    //----------------------------------------------------------------
    reg [23:0] phase_lut [0:1023];     // osc phase increment, one octave
    reg [15:0] k_lut     [0:1023];     // SVF K mantissa, one octave
    reg [16:0] q1_lut    [0:15];       // SVF damping mantissa, one
                                       // octave of the log2 resonance
                                       // code (q1 = sqrt2 * 2^-r) in
                                       // 1/16-octave steps — the
                                       // attenuation-LUT grid, ear-
                                       // proven for loudness-class
                                       // percepts; fabric
                                       // LUTs, no BSRAM block
    reg [16:0] att_lut   [0:15];       // log-gain fractional part
    reg [15:0] reso_att_lut [0:63];    // resonance-indexed input
                                       // attenuation, UQ0.16 (dual)

    initial begin
        $readmemh("dsp/phase_lut.hex", phase_lut);
        $readmemh("dsp/svf_k_lut.hex", k_lut);
        $readmemh("dsp/q1_lut.hex", q1_lut);
        $readmemh("dsp/att_lut.hex", att_lut);
        $readmemh("dsp/reso_att_lut.hex", reso_att_lut);
    end

    //----------------------------------------------------------------
    // Per-element internal state RAM — semi dual-port
    // read address: entering element (S0), write: 25 cycles later
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
    //              parameter seam)
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
    // the oscillator and filters free-run regardless. This is NOT an
    // ADSR trigger: envelopes are sequencer SOURCES, gated by a control
    // input (a gate bus shared across a voice's elements), rather than
    // element traits. GATE's only job is the exact-mute path, and
    // dropping GATE and RETRIG as element parameters entirely is under
    // discussion.
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
    logic page_active;
    logic swap_toggle_meta, swap_toggle_sync, swap_toggle_prev;          // swap_toggle sync (sysclk)
    logic swap_pending;

    initial begin
        page_active  = 1'b0;
        {swap_toggle_meta, swap_toggle_sync, swap_toggle_prev} = '0;
        swap_pending = 1'b0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            page_active  <= 1'b0;
            swap_toggle_meta <= 1'b0; swap_toggle_sync <= 1'b0; swap_toggle_prev <= 1'b0;
            swap_pending <= 1'b0;
        end else begin
            swap_toggle_meta <= swap_toggle;
            swap_toggle_sync <= swap_toggle_meta;
            swap_toggle_prev <= swap_toggle_sync;
            if (swap_toggle_sync != swap_toggle_prev)
                swap_pending <= 1'b1;
            else if (swap_pending && slot == synth_pkg::SWAP_SLOT[9:0]) begin
                page_active  <= ~page_active;
                swap_pending <= 1'b0;
            end
        end
    end

    // write side: shadow = complement of active, synced into sclk
    logic page_active_meta, page_active_sync;
    initial {page_active_meta, page_active_sync} = '0;
    always_ff @(posedge sclk) begin
        page_active_meta <= page_active;
        page_active_sync <= page_active_meta;
    end
    wire page_shadow = ~page_active_sync;

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
    // Read data validity is gated by s1_valid, so no reset is needed.
    //----------------------------------------------------------------
    logic [VW-1:0] elem_read_index;
    assign elem_read_index = slot_issue ? slot[VW-1:0] : '0;

    logic        s1_valid;
    logic [VW-1:0] s1_idx;
    logic [13:0] s1_pitch;
    logic [1:0]  s1_wave;
    logic signed [23:0] s1_duty;
    logic [13:0] s1_fc;
    logic [13:0] s1_reso;   // log2 resonance code (UQ4.10)
    logic [7:0]  s1_vol_l, s1_vol_r;
    logic        s1_cascade;
    logic [1:0]  s1_filter_mode;
    logic signed [23:0] s1_phase;
    logic signed [35:0] s1_ic1eq1, s1_ic2eq1, s1_ic1eq2, s1_ic2eq2;

    // Param RAM reads are SYNCHRONOUS on clk (was a comb read into the
    // same registers — identical timing, but sync-read + separate-clock
    // write is the shape yosys infers as dual-clock BSRAM). Sync-only
    // process: yosys does not infer BSRAM from a process with an async
    // reset. Validity is act-gated.
    logic [35:0] s1_osc_word, s1_duty_word, s1_filter_word, s1_gain_word;
    logic [1:0]  s1_gate_word;
    logic [29:0] s1_ptrs0_word, s1_ptrs1_word;
    always_ff @(posedge clk) begin
        s1_osc_word     <= osc_param_ram[{page_active, elem_read_index}];
        s1_duty_word     <= duty_param_ram[{page_active, elem_read_index}];
        s1_filter_word     <= filter_param_ram[{page_active, elem_read_index}];
        s1_gain_word     <= gain_param_ram[{page_active, elem_read_index}];
        s1_gate_word     <= gate_param_ram[{page_active, elem_read_index}];
        s1_ptrs0_word     <= ptrs0_param_ram[{page_active, elem_read_index}];
        s1_ptrs1_word     <= ptrs1_param_ram[{page_active, elem_read_index}];
        s1_phase  <= phase_ram[elem_read_index];
        s1_ic1eq1 <= ic1eq1_ram[elem_read_index];
        s1_ic2eq1 <= ic2eq1_ram[elem_read_index];
        s1_ic1eq2 <= ic1eq2_ram[elem_read_index];
        s1_ic2eq2 <= ic2eq2_ram[elem_read_index];
    end

    // SPI-side write ports (sclk domain) — sync-only, one per bank
    always_ff @(posedge sclk)
        if (elem_write_enable && elem_write_word == 3'd0) osc_param_ram[{page_shadow, elem_write_index}] <= {4'b0, elem_write_data};
    always_ff @(posedge sclk)
        if (elem_write_enable && elem_write_word == 3'd1) duty_param_ram[{page_shadow, elem_write_index}] <= {4'b0, elem_write_data};
    always_ff @(posedge sclk)
        if (elem_write_enable && elem_write_word == 3'd2) filter_param_ram[{page_shadow, elem_write_index}] <= {4'b0, elem_write_data};
    always_ff @(posedge sclk)
        if (elem_write_enable && elem_write_word == 3'd3) gain_param_ram[{page_shadow, elem_write_index}] <= {4'b0, elem_write_data};
    always_ff @(posedge sclk)
        if (elem_write_enable && elem_write_word == 3'd4) gate_param_ram[{page_shadow, elem_write_index}] <= elem_write_data[1:0];
    always_ff @(posedge sclk)
        if (elem_write_enable && elem_write_word == 3'd5) ptrs0_param_ram[{page_shadow, elem_write_index}] <= elem_write_data[29:0];
    always_ff @(posedge sclk)
        if (elem_write_enable && elem_write_word == 3'd6) ptrs1_param_ram[{page_shadow, elem_write_index}] <= elem_write_data[29:0];

    // field views of the registered param words
    assign s1_pitch = s1_osc_word[13:0];
    assign s1_wave  = s1_osc_word[15:14];
    assign s1_duty  = s1_duty_word[23:0];
    assign s1_fc    = s1_filter_word[13:0];
    assign s1_reso  = s1_filter_word[27:14];
    // GAIN word carries VOLUME (0x00 = silence.. 0xFF =
    // loudest): a zeroed parameter word is now silent-by-default
    // instead of full-blast. GATE off = volume zero, which the
    // effective-parameter stage maps onto the existing exact-mute
    // machinery:
    // one decode-stage mux, no new carry registers down the pipeline.
    assign s1_vol_l    = s1_gate_word[0] ? s1_gain_word[7:0]  : 8'h00;
    assign s1_vol_r    = s1_gate_word[0] ? s1_gain_word[15:8] : 8'h00;
    assign s1_cascade  = s1_gain_word[16];
    assign s1_filter_mode = s1_gain_word[18:17];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid   <= 1'b0;
            s1_idx   <= '0;
        end else begin
            s1_valid   <= slot_issue;
            s1_idx   <= slot[VW-1:0];
        end
    end

    //----------------------------------------------------------------
    // S2 — issue phase_inc + K LUT reads; carry everything
    //----------------------------------------------------------------
    logic        s2_valid;
    logic [VW-1:0] s2_idx;
    logic [13:0] s2_pitch;
    logic [1:0]  s2_wave;
    logic signed [23:0] s2_duty;
    logic [13:0] s2_fc;
    logic [13:0] s2_reso;
    logic [7:0]  s2_vol_l, s2_vol_r;
    logic        s2_cascade;
    logic [1:0]  s2_filter_mode;
    logic signed [23:0] s2_phase;
    logic signed [35:0] s2_ic1eq1, s2_ic2eq1, s2_ic1eq2, s2_ic2eq2;

    //----------------------------------------------------------------
    // The Control Signal Processor lives in its own module (csp.sv).
    // Six read ports: S1 pointers in, S2 data out.
    //----------------------------------------------------------------
    logic signed [17:0] s2_dmem_pitch, s2_dmem_duty, s2_dmem_fc;
    logic signed [17:0] s2_dmem_q, s2_dmem_gain_l, s2_dmem_gain_r;

    csp u_csp (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick), .sclk(sclk),
        .page_active(page_active), .page_shadow(page_shadow),
        .dmem_wr_addr(dmem_wr_addr), .dmem_wr_data(dmem_wr_data),
        .dmem_wr_toggle(dmem_wr_toggle),
        .imem_write_enable(imem_write_enable),
        .imem_write_addr(imem_write_addr),
        .imem_write_data(imem_write_data),
        .rd_pitch_a(s1_ptrs0_word[8:0]),
        .rd_duty_a (s1_ptrs0_word[18:10]),
        .rd_fc_a   (s1_ptrs0_word[28:20]),
        .rd_q_a    (s1_ptrs1_word[8:0]),
        .rd_gl_a   (s1_ptrs1_word[18:10]),
        .rd_gr_a   (s1_ptrs1_word[28:20]),
        .rd_pitch_d(s2_dmem_pitch), .rd_duty_d(s2_dmem_duty), .rd_fc_d(s2_dmem_fc),
        .rd_q_d(s2_dmem_q), .rd_gl_d(s2_dmem_gain_l), .rd_gr_d(s2_dmem_gain_r),
        .test_tone_en(test_tone_en)
    );


    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid   <= 1'b0;
            s2_idx   <= '0;
            s2_pitch <= '0;
            s2_wave  <= '0;
            s2_duty  <= '0;
            s2_fc    <= '0;
            s2_reso  <= '0;
            s2_vol_l    <= '0;
            s2_vol_r    <= '0;
            s2_cascade  <= 1'b0;
            s2_filter_mode <= '0;
            s2_phase <= '0;
            s2_ic1eq1 <= '0;
            s2_ic2eq1 <= '0;
            s2_ic1eq2 <= '0;
            s2_ic2eq2 <= '0;
        end else begin
            s2_valid   <= s1_valid;
            s2_idx   <= s1_idx;
            s2_pitch <= s1_pitch;
            s2_wave  <= s1_wave;
            s2_duty  <= s1_duty;
            s2_fc    <= s1_fc;
            s2_reso  <= s1_reso;
            s2_vol_l    <= s1_vol_l;
            s2_vol_r    <= s1_vol_r;
            s2_cascade  <= s1_cascade;
            s2_filter_mode <= s1_filter_mode;
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
    //          bus = LOUDER — volume semantics). A base of
    //          0x00 (exact mute — hard-panned channels, gated
    //          elements) is preserved regardless of the bus, and the
    //          bus alone can never reach exact mute (sums clamp to
    //          the quietest audible step). The sum is converted to
    //          the attenuation code here, at ONE seam, so everything
    //          downstream (S9B decode, mute == 0xFF) is untouched.
    //----------------------------------------------------------------
    // Resonance is log2-encoded, breaking with convention: r =
    // octaves of Q above Butterworth, UQ4.10; q1 = sqrt(2) * 2^-r via
    // q1_lut + barrel shift, the same decode shape as cutoff K. The
    // [0, sqrt2] damping clamp is STRUCTURAL: r = 0 IS Butterworth and
    // nothing decodes heavier;
    // at the top of the range the shift underflows q1 toward zero,
    // so self-oscillation is the natural top of scale — reachable as
    // a feature, no special code.
    wire signed [18:0] reso_sum =
        $signed({5'b0, s2_reso}) + {s2_dmem_q[17], s2_dmem_q};
    wire [13:0] eff_reso =
        reso_sum[18]            ? 14'd0    :
        (reso_sum > 19'sd16383) ? 14'h3FFF : reso_sum[13:0];

    // Cutoff clamps to the flat FC_MAX (14.4 kHz, measured clean at
    // the Butterworth worst case — see synth_pkg).
    wire signed [18:0] fc_sum =
        $signed({5'b0, s2_fc}) + {s2_dmem_fc[17], s2_dmem_fc};
    wire [13:0] eff_fc =
        fc_sum[18] ? 14'd0 :
        (fc_sum > 19'($signed({5'b0, synth_pkg::FC_MAX})))
            ? synth_pkg::FC_MAX :
        fc_sum[13:0];

    wire signed [18:0] pitch_sum =
        $signed({5'b0, s2_pitch}) + {s2_dmem_pitch[17], s2_dmem_pitch};
    wire [13:0] eff_pitch =
        pitch_sum[18]            ? 14'd0    :
        (pitch_sum > 19'sd16383) ? 14'h3FFF : pitch_sum[13:0];

    wire signed [31:0] duty_sum =
        {{8{s2_duty[23]}}, s2_duty}
        + {{1{s2_dmem_duty[17]}}, s2_dmem_duty, 13'b0};
    wire signed [23:0] eff_duty =
        (duty_sum >  32'sd8388607) ? 24'sd8388607  :
        (duty_sum < -32'sd8388608) ? -24'sd8388608 : duty_sum[23:0];

    wire signed [17:0] gain_mod_l = s2_dmem_gain_l >>> 6;
    wire signed [17:0] gain_mod_r = s2_dmem_gain_r >>> 6;
    wire signed [18:0] gl_sum =
        $signed({11'b0, s2_vol_l}) + {gain_mod_l[17], gain_mod_l};
    wire signed [18:0] gr_sum =
        $signed({11'b0, s2_vol_r}) + {gain_mod_r[17], gain_mod_r};
    // volume in, attenuation code out (the one subtract)
    wire [7:0] eff_atten_l =
        (s2_vol_l == 8'h00)      ? 8'hFF :             // base mute wins
        (gl_sum[18] || gl_sum == 19'sd0)
                              ? 8'hFE :             // quietest audible
        (gl_sum > 19'sd255)   ? 8'h00 :             // full volume
        8'hFF - gl_sum[7:0];
    wire [7:0] eff_atten_r =
        (s2_vol_r == 8'h00)      ? 8'hFF :
        (gr_sum[18] || gr_sum == 19'sd0)
                              ? 8'hFE :
        (gr_sum > 19'sd255)   ? 8'h00 :
        8'hFF - gr_sum[7:0];

    //----------------------------------------------------------------
    // S3 — LUT data, phase_inc/K, phase_next, oscillator waveform
    //----------------------------------------------------------------
    logic [23:0] s3_phase_inc_lut;
    logic [15:0] s3_k_lut;
    logic [16:0] s3_q1_lut;
    logic [3:0]  s3_reso_oct;

    logic        s3_valid;
    logic [VW-1:0] s3_idx;
    logic signed [23:0] s3_phase;
    logic [3:0]  s3_pitch_oct;
    logic [3:0]  s3_fc_oct;
    logic [1:0]  s3_wave;
    logic signed [23:0] s3_duty;
    logic [7:0]  s3_atten_l, s3_atten_r;
    logic        s3_cascade;
    logic [1:0]  s3_filter_mode;
    logic [15:0] s3_reso_att;   // input-atten gain (UQ0.16)
    logic signed [35:0] s3_ic1eq1, s3_ic2eq1, s3_ic1eq2, s3_ic2eq2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_phase_inc_lut <= '0;
            s3_k_lut     <= '0;
            s3_q1_lut    <= '0;
            s3_reso_oct  <= '0;
            s3_valid   <= 1'b0;
            s3_idx   <= '0;
            s3_phase <= '0;
            s3_pitch_oct <= '0;
            s3_fc_oct    <= '0;
            s3_wave  <= '0;
            s3_duty  <= '0;
            s3_atten_l    <= '0;
            s3_atten_r    <= '0;
            s3_cascade  <= 1'b0;
            s3_filter_mode <= '0;
            s3_reso_att <= 16'hffff;
            s3_ic1eq1 <= '0;
            s3_ic2eq1 <= '0;
            s3_ic1eq2 <= '0;
            s3_ic2eq2 <= '0;
        end else begin
            s3_phase_inc_lut <= phase_lut[eff_pitch[9:0]];
            s3_k_lut     <= k_lut[eff_fc[9:0]];
            s3_q1_lut    <= q1_lut[eff_reso[9:6]];
            s3_reso_oct  <= eff_reso[13:10];
            s3_valid   <= s2_valid;
            s3_idx   <= s2_idx;
            s3_phase <= s2_phase;
            s3_pitch_oct <= eff_pitch[13:10];
            s3_fc_oct    <= eff_fc[13:10];
            s3_wave  <= s2_wave;
            s3_duty  <= eff_duty;
            s3_atten_l    <= eff_atten_l;
            s3_atten_r    <= eff_atten_r;
            s3_cascade  <= s2_cascade;
            s3_filter_mode <= s2_filter_mode;
            s3_reso_att <= s2_cascade ? reso_att_lut[eff_reso[13:8]] : 16'hffff;
            s3_ic1eq1 <= s2_ic1eq1;
            s3_ic2eq1 <= s2_ic2eq1;
            s3_ic1eq2 <= s2_ic1eq2;
            s3_ic2eq2 <= s2_ic2eq2;
        end
    end

    // S3 combinational datapath
    logic signed [23:0] phase_inc;
    logic signed [35:0] k;
    logic signed [17:0] osc_sample;

    assign phase_inc = $signed(s3_phase_inc_lut) >>> (11 - s3_pitch_oct);
    // K stays full-width — do NOT narrow to 18-bit to save DSPs: the
    // LUT+shift expands to ~22+ bits of real precision, needed later
    // for the noise oscillator and whistling-filter melodies.
    assign k     = $signed({20'd0, s3_k_lut}) <<< (3 + s3_fc_oct);
    // Resonance decode: q1 = sqrt(2) * 2^-r in Q2.16. Same
    // LUT+barrel-shift shape as K; registered into S3B before the
    // S4 multiply (the silicon timing rule). At high octaves the
    // shift underflows to 0 — self-oscillation, by design.
    wire signed [17:0] q1_decoded =
        $signed({1'b0, s3_q1_lut}) >>> s3_reso_oct;

    // The phase advance is ONE adder, here, and its result is
    // REGISTERED (s3b_phase) before any waveform is generated from it.
    // Computing it twice -- once inside osc_core feeding the
    // waveforms, once below for the writeback -- hangs the waveform
    // path off the combinational sum, giving one cycle of
    // BSRAM read -> octave shift -> 24-bit add -> sine LUT -> mux.
    // That was the critical path of the whole design.
    wire signed [23:0] phase_next = s3_phase + phase_inc;

    //----------------------------------------------------------------
    // S3B/S3C -- resonance-dependent INPUT attenuation. Scale the
    // oscillator sample down as resonance rises so the 24 dB/oct dual
    // cascade never overdrives its internal +-8 guardrail (sat_q414).
    // Register-then-multiply: S3B registers osc + the (dual-gated) atten
    // and every SVF operand; S3C multiplies. Keeps the osc_core->reg
    // critical path intact (no combinational mult in it). Single (12
    // dB/oct) never overdrives, so its atten is unity (0xffff).
    //----------------------------------------------------------------
    // S3B registers the ADVANCED PHASE (and duty/wave alongside it); the
    // waveform is generated from the registered value in S3B->S3C.
    logic               s3b_valid;   logic [VW-1:0] s3b_idx;
    logic [15:0] s3b_att;
    logic signed [35:0] s3b_k;     logic signed [17:0] s3b_q1;
    logic signed [35:0] s3b_ic1eq1, s3b_ic2eq1, s3b_ic1eq2, s3b_ic2eq2;
    logic               s3b_cascade;  logic [1:0] s3b_filter_mode;
    logic signed [23:0] s3b_phase; logic [7:0] s3b_atten_l, s3b_atten_r;
    logic signed [23:0] s3b_duty;  logic [1:0] s3b_wave;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3b_valid<=1'b0; s3b_idx<='0; s3b_att<='0;
            s3b_k<='0; s3b_q1<='0; s3b_ic1eq1<='0; s3b_ic2eq1<='0;
            s3b_ic1eq2<='0; s3b_ic2eq2<='0; s3b_cascade<=1'b0; s3b_filter_mode<='0;
            s3b_phase<='0; s3b_atten_l<='0; s3b_atten_r<='0;
            s3b_duty<='0; s3b_wave<='0;
        end else begin
            s3b_valid<=s3_valid; s3b_idx<=s3_idx;
            s3b_att<=s3_reso_att; s3b_k<=k; s3b_q1<=q1_decoded;
            s3b_ic1eq1<=s3_ic1eq1; s3b_ic2eq1<=s3_ic2eq1;
            s3b_ic1eq2<=s3_ic1eq2; s3b_ic2eq2<=s3_ic2eq2;
            s3b_cascade<=s3_cascade; s3b_filter_mode<=s3_filter_mode;
            s3b_phase<=phase_next; s3b_atten_l<=s3_atten_l; s3b_atten_r<=s3_atten_r;
            s3b_duty<=s3_duty; s3b_wave<=s3_wave;
        end
    end

    // Waveform generation stands alone in its own stage, driven by the
    // REGISTERED phase: a sine LUT read plus a 4:1 mux, which must not
    // be chained behind the phase adder.
    osc_core u_osc (
        .phase_next (s3b_phase),
        .duty       (s3b_duty),
        .wave       (s3b_wave),
        .sample_out (osc_sample)
    );

    // S3C registers the WAVEFORM (was: the attenuation product). The
    // multiply moves to S3D so nothing chains a mux into a DSP.
    logic               s3c_valid;   logic [VW-1:0] s3c_idx;
    logic signed [17:0] s3c_osc;   logic [15:0] s3c_att;
    logic signed [35:0] s3c_k;     logic signed [17:0] s3c_q1;
    logic signed [35:0] s3c_ic1eq1, s3c_ic2eq1, s3c_ic1eq2, s3c_ic2eq2;
    logic               s3c_cascade;  logic [1:0] s3c_filter_mode;
    logic signed [23:0] s3c_phase; logic [7:0] s3c_atten_l, s3c_atten_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3c_valid<=1'b0; s3c_idx<='0; s3c_osc<='0; s3c_att<='0;
            s3c_k<='0; s3c_q1<='0;
            s3c_ic1eq1<='0; s3c_ic2eq1<='0; s3c_ic1eq2<='0; s3c_ic2eq2<='0;
            s3c_cascade<=1'b0; s3c_filter_mode<='0; s3c_phase<='0; s3c_atten_l<='0; s3c_atten_r<='0;
        end else begin
            s3c_valid<=s3b_valid; s3c_idx<=s3b_idx;
            s3c_osc <= osc_sample; s3c_att <= s3b_att;
            s3c_k<=s3b_k; s3c_q1<=s3b_q1;
            s3c_ic1eq1<=s3b_ic1eq1; s3c_ic2eq1<=s3b_ic2eq1;
            s3c_ic1eq2<=s3b_ic1eq2; s3c_ic2eq2<=s3b_ic2eq2;
            s3c_cascade<=s3b_cascade; s3c_filter_mode<=s3b_filter_mode;
            s3c_phase<=s3b_phase; s3c_atten_l<=s3b_atten_l; s3c_atten_r<=s3b_atten_r;
        end
    end

    //----------------------------------------------------------------
    // S3D -- the attenuation multiply, on REGISTERED operands. It sits
    // one stage after the waveform stage so that no cycle chains the
    // waveform mux into a DSP. The state writeback lands 25 cycles
    // after the read, against a 256-slot half, so read and write still
    // cannot collide.
    //----------------------------------------------------------------
    wire signed [35:0] osc_mul = s3c_osc * $signed({1'b0, s3c_att});
    logic               s3d_valid;   logic [VW-1:0] s3d_idx;
    logic signed [17:0] s3d_osc;
    logic signed [35:0] s3d_k;     logic signed [17:0] s3d_q1;
    logic signed [35:0] s3d_ic1eq1, s3d_ic2eq1, s3d_ic1eq2, s3d_ic2eq2;
    logic               s3d_cascade;  logic [1:0] s3d_filter_mode;
    logic signed [23:0] s3d_phase; logic [7:0] s3d_atten_l, s3d_atten_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3d_valid<=1'b0; s3d_idx<='0; s3d_osc<='0; s3d_k<='0; s3d_q1<='0;
            s3d_ic1eq1<='0; s3d_ic2eq1<='0; s3d_ic1eq2<='0; s3d_ic2eq2<='0;
            s3d_cascade<=1'b0; s3d_filter_mode<='0; s3d_phase<='0; s3d_atten_l<='0; s3d_atten_r<='0;
        end else begin
            s3d_valid<=s3c_valid; s3d_idx<=s3c_idx;
            s3d_osc <= 18'($signed(osc_mul >>> 16));
            s3d_k<=s3c_k; s3d_q1<=s3c_q1;
            s3d_ic1eq1<=s3c_ic1eq1; s3d_ic2eq1<=s3c_ic2eq1;
            s3d_ic1eq2<=s3c_ic1eq2; s3d_ic2eq2<=s3c_ic2eq2;
            s3d_cascade<=s3c_cascade; s3d_filter_mode<=s3c_filter_mode;
            s3d_phase<=s3c_phase; s3d_atten_l<=s3c_atten_l; s3d_atten_r<=s3c_atten_r;
        end
    end

    //----------------------------------------------------------------
    // SVF core (TPT), stages S4..S9.
    //   g = k>>1 (= pi*fc/fs), R2 = q1, h = 1/D via reciprocal LUT.
    //   Unconditionally stable under cutoff-modulation-at-resonance.
    //   Streaming, latency 17; states/phase/gains carried through.
    //   See rtl/dsp/svf_tpt.sv.
    //----------------------------------------------------------------
    wire               s9_valid;
    wire [VW-1:0]      s9_idx;
    wire signed [17:0] s9_elem;
    wire signed [23:0] s9_phase;
    wire signed [35:0] s9_ic1eq1n, s9_ic2eq1n, s9_ic1eq2n, s9_ic2eq2n;
    wire [7:0]         s9_atten_l, s9_atten_r;

    svf_tpt #(.IDXW(VW)) u_svf (
        .clk(clk), .rst_n(rst_n),
        .in_valid(s3d_valid), .in_idx(s3d_idx),
        .in_osc(s3d_osc), .in_k(s3d_k), .in_q1(s3d_q1),
        .in_ic1eq1(s3d_ic1eq1), .in_ic2eq1(s3d_ic2eq1),
        .in_ic1eq2(s3d_ic1eq2), .in_ic2eq2(s3d_ic2eq2),
        .in_cascade(s3d_cascade), .in_filter_mode(s3d_filter_mode),
        .in_phase(s3d_phase), .in_atten_l(s3d_atten_l), .in_atten_r(s3d_atten_r),
        .out_valid(s9_valid), .out_idx(s9_idx), .out_elem(s9_elem),
        .out_ic1eq1n(s9_ic1eq1n), .out_ic2eq1n(s9_ic2eq1n),
        .out_ic1eq2n(s9_ic1eq2n), .out_ic2eq2n(s9_ic2eq2n),
        .out_phase(s9_phase), .out_atten_l(s9_atten_l), .out_atten_r(s9_atten_r)
    );

    //----------------------------------------------------------------
    // S9B — attenuation decode: lin = att_lut[frac] >>> int, REGISTERED
    //
    //   gain UQ4.4: att_lut[i] = 2^(-i/16) in UQ0.16 → 6 dB per int
    //   step, 0.375 dB per frac step.
    //
    // Split from the multiply for the silicon timing rule (see the
    // header): LUT read + 16-position barrel shift chained into a DSP
    // multiply in one cycle violates setup on real silicon, audibly,
    // on whichever channel draws the longer route. Decode and multiply
    // are separate stages.
    //----------------------------------------------------------------
    logic        s9b_valid;
    logic [VW-1:0] s9b_idx;
    logic signed [17:0] s9b_elem;
    logic signed [17:0] s9b_lin_l, s9b_lin_r;
    logic signed [23:0] s9b_phase;
    logic signed [35:0] s9b_ic1eq1n, s9b_ic2eq1n, s9b_ic1eq2n, s9b_ic2eq2n;

    // Gain 0xFF is EXACT mute, not -96 dB: the log decode bottoms out at
    // lin = raw value 1, and 256 correlated muted elements sum 48 dB of that
    // right back (measured: -48 dBFS of ghost organ). A muted voice
    // must contribute zero.
    logic signed [17:0] lin_l, lin_r;
    always_comb begin
        lin_l = (s9_atten_l == 8'hFF) ? 18'sd0
              : 18'($signed({1'b0, att_lut[s9_atten_l[3:0]]})) >>> s9_atten_l[7:4];
        lin_r = (s9_atten_r == 8'hFF) ? 18'sd0
              : 18'($signed({1'b0, att_lut[s9_atten_r[3:0]]})) >>> s9_atten_r[7:4];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s9b_valid  <= 1'b0;
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
            s9b_valid  <= s9_valid;
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
    logic        s10_valid;
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
            s10_valid  <= 1'b0;
            s10_idx  <= '0;
            s10_outl <= '0;
            s10_outr <= '0;
            s10_phase <= '0;
            s10_ic1eq1n <= '0;
            s10_ic2eq1n <= '0;
            s10_ic1eq2n <= '0;
            s10_ic2eq2n <= '0;
        end else begin
            s10_valid  <= s9b_valid;
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
    // loudness is set by the per-element UQ4.4 gains: −2 bits of audio
    // scale cancel the +2 bits of conversion shift.
    //----------------------------------------------------------------
    function automatic logic signed [23:0] sat24(input logic signed [35:0] x);
        if (x > 36'sd8388607)
            sat24 = 24'sd8388607;
        else if (x < -36'sd8388608)
            sat24 = -24'sd8388608;
        else
            sat24 = x[23:0];
    endfunction

    logic signed [25:0] mix_acc_l, mix_acc_r;   // Q4.14 audio + 8 guard bits

    //----------------------------------------------------------------
    // S11 master limiter: log-domain peak limiter on the PRE-clip
    // accumulators, attenuating before the clamp, stereo-linked on
    // max(|L|,|R|), FEEDFORWARD (this
    // sample's level gates this sample), then sat24. Fully registered,
    // one operation class per stage (the silicon timing rule): the first
    // cut computed abs -> max -> lzc -> shift -> LUT -> adds -> LUT ->
    // shift in ONE cycle, passed STA, and sputtered at -63 dBFS on the
    // board. 768 cycles of slack per sample, so the phase
    // walk is free:  p1 abs | p2 max -> level | p3..p7 limiter pipeline
    // settles (5 stages) | p8 latch gain_q + gain | p9 multiply | p10
    // sat24 publish. Every consumer latches mix_* at the NEXT tick, so
    // audio semantics are unchanged. lim_gain_q persists across samples
    // = the envelope. Constants: threshold code 192 = −6 dBFS (one
    // octave under the full-scale code 208), attack 1/8 code ≈ 0.05 dB
    // per sample, release 1/2048 code per sample ≈ 17.6 dB/s. sat24 stays
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
    logic        [3:0]  lim_step;
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
            mix_acc_l  <= '0;
            mix_acc_r  <= '0;
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
            lim_step  <= 4'd0;
        end else begin
            if (sample_tick) begin
                // sample boundary: hold the finished sum for the
                // limiter, start accumulating the next sample
                lim_acc_l  <= mix_acc_l;
                lim_acc_r  <= mix_acc_r;
                mix_acc_l  <= '0;
                mix_acc_r  <= '0;
                lim_step  <= 4'd1;
            end else if (s10_valid) begin
                mix_acc_l <= mix_acc_l + {{8{s10_outl[17]}}, s10_outl};
                mix_acc_r <= mix_acc_r + {{8{s10_outr[17]}}, s10_outr};
            end
            case (lim_step)
                4'd1: begin   // |acc|: explicit two's-complement negate on the bits
                    lim_abs_l <= lim_acc_l[25] ? (~lim_acc_l + 26'd1) : lim_acc_l;
                    lim_abs_r <= lim_acc_r[25] ? (~lim_acc_r + 26'd1) : lim_acc_r;
                    lim_step <= 4'd2;
                end
                4'd2: begin   // stereo link: the louder channel gates both
                    lim_level <= (lim_abs_l > lim_abs_r) ? lim_abs_l : lim_abs_r;
                    lim_step <= 4'd3;
                end
                4'd3, 4'd4, 4'd5, 4'd6, 4'd7:   // limiter pipeline settles
                    lim_step <= lim_step + 4'd1;
                4'd8: begin   // both outputs valid (gain_q from p7, gain from p8)
                    lim_gain_q <= lim_gain_q_next;
                    lim_gain   <= lim_gain_lin;
                    lim_step  <= 4'd9;
                end
                4'd9: begin   // apply the gain
                    lim_prod_l <= 26'(lim_mul_l >>> 16);
                    lim_prod_r <= 26'(lim_mul_r >>> 16);
                    lim_step  <= 4'd10;
                end
                4'd10: begin  // Q4.14 -> Q0.24, rail
                    mix_left   <= sat24(36'(lim_prod_l) <<< 10);
                    mix_right  <= sat24(36'(lim_prod_r) <<< 10);
                    lim_step  <= 4'd0;
                end
                default: ;
            endcase
        end
    end

    // State writeback — sync-only process (BSRAM write port).
    // Writeback lands 25 cycles after the read, so read and write
    // addresses can never collide (25 < 256).
    always_ff @(posedge clk) begin
        if (s10_valid) begin
            phase_ram[s10_idx]  <= s10_phase;
            ic1eq1_ram[s10_idx] <= s10_ic1eq1n;
            ic2eq1_ram[s10_idx] <= s10_ic2eq1n;
            ic1eq2_ram[s10_idx] <= s10_ic1eq2n;
            ic2eq2_ram[s10_idx] <= s10_ic2eq2n;
        end
    end

endmodule
