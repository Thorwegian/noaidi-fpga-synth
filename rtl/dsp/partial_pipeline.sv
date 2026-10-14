//--------------------------------------------------------------------
// partial_pipeline.sv — 256-partial time-division-multiplexed pipeline
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The partial pipeline is a time-division-multiplexed pipeline: one
// datapath, 256 partials, one every two sysclk cycles. A partial is
// pointers only (docs/csp_isa.md section 6): its pointer entry names ten
// words of the sink area, which the CSP publishes, and the pipeline reads
// them over two cycles. Every cycle, every stage processes a different
// partial: a partial enters at time slot 2p and the front end is complete
// at slot 2p + 4. The pipeline is deep, so the 256 partials occupy about
// 540 of the sample period's 768 slots.
//
// Stage map:
//   F0  the pointer RAM's read address
//   F1  the pointers; the first six sink words are addressed
//   F2  the first six sink words; the last four are addressed
//   F3  the last four sink words; the state RAM's read address
//   S1  sink words and state in registers
//   S2  the pitch and cutoff sums (voice word + channel word)
//   S3  effective parameters: biases, clamps, LUT reads; phase_next
//   S3B register phase_next / barrel-shifted K / q1 / duty / wave
//   S3C oscillator waveform from the REGISTERED phase (sine LUT + mux);
//       the gain products (voice word × channel word)
//   S3D resonance attenuation multiply on registered operands (DSP);
//       the gains scaled and clamped
//   S4..S9  svf_tpt: 17 registered stages (1 input, 2 coefficient,
//       7 per 2-pole section); its output is the partial output
//   S10 gain multiply on registered operands                (DSP); its
//       output is accumulated into the mix and the state written back
//
// S3B/S3C/S3D exist because chaining adder trees or LUT+barrel-
// shift decodes into a DSP multiply in one cycle violated setup on
// real silicon at 98.304 MHz (audible corruption, clean at half
// clock) — paths nextpnr's approximate timing model passes. Rule: a
// stage is adds/decode-only or multiply-only, never both chained.
// S3B is the last of the class: when per-partial fc gives consecutive
// partials different K shift amounts, a chord screams in the left
// channel, because the glitched issue slot after a group boundary
// carries a left-panned partial. No known residual of this class remains.
//
// Number formats (design doc):
//   phase      UQ0.24  (24-bit)
//   audio      Q4.14   (18-bit; clamp ±8.0, which is +12 dB of
//              resonance headroom)
//   SVF states Q8.28   (36-bit)
//   pitch/fc   UQ4.10  (14-bit)
//   sink words Q4.14   (18-bit): pitch and cutoff in octaves from
//              middle C, resonance in octaves of Q, duty with 1.0 the
//              rail, gain linear (see the effective parameters)
//
// State RAM is semi dual-port: the read address is issued with the
// partial at F3, writeback happens about 25 cycles later — the read
// and write addresses can never collide.
//--------------------------------------------------------------------
`default_nettype none
module partial_pipeline #(
    parameter int NUM_PARTIALS = synth_pkg::NUM_PARTIALS
) (
    input  logic           clk,
    input  logic           rst_n,

    input  logic [9:0]     slot,
    input  logic           slot_issue,      // slots 0 … 2 × NUM_PARTIALS − 1
    input  logic           sample_tick,

    // The pointer RAM's write port, in the SPI clock domain: one whole
    // entry at a time, valid exactly on the sclk edge that completes the
    // entry (the master may stop clocking after it). The dual-clock BSRAM
    // is the clock-domain crossing; a partial's entry changes atomically.
    input  logic           sclk,
    input  logic           pointer_write_enable,
    input  logic [7:0]     pointer_write_index,
    input  logic [synth_pkg::POINTER_ENTRY_W-1:0] pointer_write_data,

    // The sink area (csp_sink_area): six read ports, a word a cycle
    // after its address.
    output logic [synth_pkg::SINK_READ_PORTS-1:0][9:0]  sink_read_address,
    input  logic [synth_pkg::SINK_READ_PORTS-1:0][17:0] sink_read_data,

    output logic signed [23:0] mix_left,    // Q0.24, published 10 cycles
                                             // after sample_tick (S11
                                             // limiter); stable by
                                             // the next tick, which is when
                                             // every consumer latches it
    output logic signed [23:0] mix_right
);

    localparam int VW = $clog2(NUM_PARTIALS);   // partial index width

    //----------------------------------------------------------------
    // LUT ROMs (combinational reads)
    //----------------------------------------------------------------
    reg [23:0] phase_lut [0:1023];     // osc phase increment, one octave
    reg [15:0] svf_fc_lut     [0:1023];     // SVF K mantissa, one octave
    reg [16:0] q1_lut    [0:15];       // SVF damping mantissa, one
                                       // octave of the log2 resonance
                                       // code (q1 = sqrt2 * 2^-r) in
                                       // 1/16-octave steps — the
                                       // attenuation-LUT grid, ear-
                                       // proven for loudness-class
                                       // percepts; fabric
                                       // LUTs, no BSRAM block
    reg [15:0] reso_att_lut [0:63];    // resonance-indexed input
                                       // attenuation, UQ0.16 (cascade)

    initial begin
        $readmemh("dsp/phase_lut.hex", phase_lut);
        $readmemh("dsp/svf_fc_lut.hex", svf_fc_lut);
        $readmemh("dsp/q1_lut.hex", q1_lut);
        $readmemh("dsp/reso_att_lut.hex", reso_att_lut);
    end

    //----------------------------------------------------------------
    // Per-partial internal state RAM — semi dual-port
    //----------------------------------------------------------------
    reg signed [23:0] phase_ram  [0:NUM_PARTIALS-1];
    reg signed [35:0] ic1eq1_ram [0:NUM_PARTIALS-1];
    reg signed [35:0] ic2eq1_ram [0:NUM_PARTIALS-1];
    reg signed [35:0] ic1eq2_ram [0:NUM_PARTIALS-1];
    reg signed [35:0] ic2eq2_ram [0:NUM_PARTIALS-1];

    // State RAMs start at zero (power-on init; also keeps X out of sim)
    integer i0;
    initial begin
        for (i0 = 0; i0 < NUM_PARTIALS; i0 = i0 + 1) begin
            phase_ram[i0]  = '0;
            ic1eq1_ram[i0] = '0;
            ic2eq1_ram[i0] = '0;
            ic1eq2_ram[i0] = '0;
            ic2eq2_ram[i0] = '0;
        end
    end

    //----------------------------------------------------------------
    // The pointer RAM: ten pointers a partial, 100 bits in three
    // 36-bit-wide blocks. Written whole in the SPI clock, read in the
    // system clock; nothing else about a partial is stored here, and it
    // needs no second page because an entry changes atomically and only
    // when the voice layout does.
    //----------------------------------------------------------------
    localparam int POINTER_RAM_W = 108;
    // One array a block: a memory with one write port is what maps to a
    // BSRAM, where a three-block array would be one memory with three.
    reg [35:0] pointer_block_0 [0:NUM_PARTIALS-1];
    reg [35:0] pointer_block_1 [0:NUM_PARTIALS-1];
    reg [35:0] pointer_block_2 [0:NUM_PARTIALS-1];
    initial begin
        for (int partial = 0; partial < NUM_PARTIALS; partial++) begin
            pointer_block_0[partial] = '0;   // every pointer at sink word 0
            pointer_block_1[partial] = '0;
            pointer_block_2[partial] = '0;
        end
    end

    wire [POINTER_RAM_W-1:0] pointer_write_word = POINTER_RAM_W'(pointer_write_data);
    always_ff @(posedge sclk) begin
        if (pointer_write_enable) begin
            pointer_block_0[pointer_write_index] <= pointer_write_word[35:0];
        end
    end
    always_ff @(posedge sclk) begin
        if (pointer_write_enable) begin
            pointer_block_1[pointer_write_index] <= pointer_write_word[71:36];
        end
    end
    always_ff @(posedge sclk) begin
        if (pointer_write_enable) begin
            pointer_block_2[pointer_write_index] <= pointer_write_word[107:72];
        end
    end

    //----------------------------------------------------------------
    // F0/F1 — the pointer RAM read. A partial enters every second slot.
    //----------------------------------------------------------------
    wire             partial_start = slot_issue && !slot[0];
    wire [VW-1:0]    partial_index = slot[VW:1];

    logic [POINTER_RAM_W-1:0] f1_entry;
    always_ff @(posedge clk) begin
        f1_entry[35:0]   <= pointer_block_0[partial_index];
        f1_entry[71:36]  <= pointer_block_1[partial_index];
        f1_entry[107:72] <= pointer_block_2[partial_index];
    end

    function automatic logic [synth_pkg::POINTER_W-1:0] pointer_of(
            input logic [POINTER_RAM_W-1:0] entry, input int position);
        pointer_of = entry[position * synth_pkg::POINTER_W +: synth_pkg::POINTER_W];
    endfunction

    logic            f1_valid, f2_valid, f3_valid;
    logic [VW-1:0]   f1_idx, f2_idx, f3_idx;
    logic [synth_pkg::POINTER_W-1:0] f2_pointer [synth_pkg::POINTERS_PER_PARTIAL - synth_pkg::SINK_READ_PORTS];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f1_valid <= 1'b0;  f1_idx <= '0;
            f2_valid <= 1'b0;  f2_idx <= '0;
            f3_valid <= 1'b0;  f3_idx <= '0;
        end else begin
            f1_valid <= partial_start;  f1_idx <= partial_index;
            f2_valid <= f1_valid;       f2_idx <= f1_idx;
            f3_valid <= f2_valid;       f3_idx <= f2_idx;
        end
    end

    // F1: the first six words. F2: the last four, with the pointers kept
    // from F1. A partial is in F1 on odd slots and in F2 on even ones, so
    // the ports never serve two partials at once.
    always_ff @(posedge clk) begin
        for (int second = 0; second < synth_pkg::POINTERS_PER_PARTIAL - synth_pkg::SINK_READ_PORTS; second++) begin
            f2_pointer[second] <= pointer_of(f1_entry, synth_pkg::SINK_READ_PORTS + second);
        end
    end

    always_comb begin
        for (int port = 0; port < synth_pkg::SINK_READ_PORTS; port++) begin
            if (f1_valid) begin
                sink_read_address[port] = 10'(pointer_of(f1_entry, port));
            end else if (port < synth_pkg::POINTERS_PER_PARTIAL - synth_pkg::SINK_READ_PORTS) begin
                sink_read_address[port] = 10'(f2_pointer[port]);
            end else begin
                sink_read_address[port] = '0;
            end
        end
    end

    //----------------------------------------------------------------
    // F2/F3 — the sink words. The first six arrive in F2 and wait a
    // cycle; the last four arrive in F3, with the state RAM's data.
    //----------------------------------------------------------------
    logic signed [17:0] f3_word [synth_pkg::SINK_READ_PORTS];
    always_ff @(posedge clk) begin
        for (int port = 0; port < synth_pkg::SINK_READ_PORTS; port++) begin
            f3_word[port] <= sink_read_data[port];
        end
    end

    //----------------------------------------------------------------
    // S1 — everything the partial needs, in registers. State RAM reads
    // are synchronous on clk, issued in F3.
    //----------------------------------------------------------------
    logic        s1_valid;
    logic [VW-1:0] s1_idx;
    logic signed [17:0] s1_pitch_voice, s1_pitch_channel;
    logic signed [17:0] s1_cutoff_voice, s1_cutoff_channel;
    logic signed [17:0] s1_gain_voice, s1_gain_left, s1_gain_right;
    logic signed [17:0] s1_duty, s1_resonance, s1_mode;
    logic signed [23:0] s1_phase;
    logic signed [35:0] s1_ic1eq1, s1_ic2eq1, s1_ic1eq2, s1_ic2eq2;

    always_ff @(posedge clk) begin
        s1_phase  <= phase_ram[f3_idx];
        s1_ic1eq1 <= ic1eq1_ram[f3_idx];
        s1_ic2eq1 <= ic2eq1_ram[f3_idx];
        s1_ic1eq2 <= ic1eq2_ram[f3_idx];
        s1_ic2eq2 <= ic2eq2_ram[f3_idx];

        // the first group, held from F2
        s1_pitch_voice    <= f3_word[synth_pkg::POINTER_PITCH_VOICE];
        s1_pitch_channel  <= f3_word[synth_pkg::POINTER_PITCH_CHANNEL];
        s1_cutoff_voice   <= f3_word[synth_pkg::POINTER_CUTOFF_VOICE];
        s1_cutoff_channel <= f3_word[synth_pkg::POINTER_CUTOFF_CHANNEL];
        s1_gain_voice     <= f3_word[synth_pkg::POINTER_GAIN_VOICE];
        s1_gain_left      <= f3_word[synth_pkg::POINTER_GAIN_LEFT];
        // the second group, arriving now
        s1_gain_right     <= sink_read_data[synth_pkg::POINTER_GAIN_RIGHT - synth_pkg::SINK_READ_PORTS];
        s1_duty           <= sink_read_data[synth_pkg::POINTER_DUTY - synth_pkg::SINK_READ_PORTS];
        s1_resonance      <= sink_read_data[synth_pkg::POINTER_RESONANCE - synth_pkg::SINK_READ_PORTS];
        s1_mode           <= sink_read_data[synth_pkg::POINTER_MODE - synth_pkg::SINK_READ_PORTS];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_idx   <= '0;
        end else begin
            s1_valid <= f3_valid;
            s1_idx   <= f3_idx;
        end
    end

    //----------------------------------------------------------------
    // S2 — the sums of a voice word and a channel word (adds only), and
    // the rest carried
    //----------------------------------------------------------------
    logic        s2_valid;
    logic [VW-1:0] s2_idx;
    logic signed [18:0] s2_pitch_sum, s2_cutoff_sum;
    logic signed [17:0] s2_gain_voice, s2_gain_left, s2_gain_right;
    logic signed [17:0] s2_duty, s2_resonance;
    logic [1:0]  s2_wave;
    logic        s2_cascade;
    logic [1:0]  s2_filter_mode;
    logic signed [23:0] s2_phase;
    logic signed [35:0] s2_ic1eq1, s2_ic2eq1, s2_ic1eq2, s2_ic2eq2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid   <= 1'b0;
            s2_idx   <= '0;
            s2_pitch_sum <= '0;
            s2_cutoff_sum <= '0;
            s2_gain_voice <= '0;
            s2_gain_left <= '0;
            s2_gain_right <= '0;
            s2_duty  <= '0;
            s2_resonance <= '0;
            s2_wave  <= '0;
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
            s2_pitch_sum  <= {s1_pitch_voice[17], s1_pitch_voice}
                           + {s1_pitch_channel[17], s1_pitch_channel};
            s2_cutoff_sum <= {s1_cutoff_voice[17], s1_cutoff_voice}
                           + {s1_cutoff_channel[17], s1_cutoff_channel};
            s2_gain_voice <= s1_gain_voice;
            s2_gain_left  <= s1_gain_left;
            s2_gain_right <= s1_gain_right;
            s2_duty  <= s1_duty;
            s2_resonance <= s1_resonance;
            // the mode word: [1:0] waveform, [2] cascade, [4:3] filter type
            s2_wave  <= s1_mode[1:0];
            s2_cascade  <= s1_mode[2];
            s2_filter_mode <= s1_mode[4:3];
            s2_phase <= s1_phase;
            s2_ic1eq1 <= s1_ic1eq1;
            s2_ic2eq1 <= s1_ic2eq1;
            s2_ic1eq2 <= s1_ic1eq2;
            s2_ic2eq2 <= s1_ic2eq2;
        end
    end

    //----------------------------------------------------------------
    // Effective parameters, SATURATING into each parameter's legal range
    // so extreme sink values clamp instead of wrapping: adds, shifts and
    // clamps only, no multiply, within the silicon timing rule. Sink words
    // are Q4.14, 2^14 to the unit; the pipeline's pitch, cutoff and
    // resonance are UQ4.10, 2^10 to the octave, so a word is shifted right
    // by four.
    //   pitch, cutoff: octaves from middle C, biased to the pipeline's
    //          scale (synth_pkg::PITCH_REFERENCE); the cutoff clamps to
    //          the flat FC_MAX
    //   resonance: octaves of Q above Butterworth, never below it
    //   duty:  Q4.14 → Q0.24 with 1.0 = 2^23, <<< 9
    //----------------------------------------------------------------
    wire signed [18:0] pitch_octaves = (s2_pitch_sum >>> 4)
                                       + 19'($signed({5'b0, synth_pkg::PITCH_REFERENCE}));
    wire [13:0] eff_pitch =
        pitch_octaves[18]            ? 14'd0    :
        (pitch_octaves > 19'sd16383) ? 14'h3FFF : pitch_octaves[13:0];

    wire signed [18:0] cutoff_octaves = (s2_cutoff_sum >>> 4)
                                        + 19'($signed({5'b0, synth_pkg::PITCH_REFERENCE}));
    wire [13:0] eff_fc =
        cutoff_octaves[18] ? 14'd0 :
        (cutoff_octaves > 19'($signed({5'b0, synth_pkg::FC_MAX})))
            ? synth_pkg::FC_MAX :
        cutoff_octaves[13:0];

    wire signed [17:0] resonance_octaves = s2_resonance >>> 4;
    wire [13:0] eff_reso =
        resonance_octaves[17] ? 14'd0 : resonance_octaves[13:0];

    wire signed [26:0] duty_scaled = 27'(s2_duty) <<< 9;
    wire signed [23:0] eff_duty =
        (duty_scaled >  27'sd8388607) ? 24'sd8388607  :
        (duty_scaled < -27'sd8388608) ? -24'sd8388608 : duty_scaled[23:0];

    //----------------------------------------------------------------
    // S3 — LUT data, phase_inc/K, phase_next, oscillator waveform
    //----------------------------------------------------------------
    logic [23:0] s3_phase_inc_lut;
    logic [15:0] s3_svf_fc_lut;
    logic [16:0] s3_q1_lut;
    logic [3:0]  s3_reso_oct;

    logic        s3_valid;
    logic [VW-1:0] s3_idx;
    logic signed [23:0] s3_phase;
    logic [3:0]  s3_pitch_oct;
    logic [3:0]  s3_fc_oct;
    logic [1:0]  s3_wave;
    logic signed [23:0] s3_duty;
    logic signed [17:0] s3_gain_voice, s3_gain_left, s3_gain_right;
    logic        s3_cascade;
    logic [1:0]  s3_filter_mode;
    logic [15:0] s3_reso_att;   // input-atten gain (UQ0.16)
    logic signed [35:0] s3_ic1eq1, s3_ic2eq1, s3_ic1eq2, s3_ic2eq2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_phase_inc_lut <= '0;
            s3_svf_fc_lut     <= '0;
            s3_q1_lut    <= '0;
            s3_reso_oct  <= '0;
            s3_valid   <= 1'b0;
            s3_idx   <= '0;
            s3_phase <= '0;
            s3_pitch_oct <= '0;
            s3_fc_oct    <= '0;
            s3_wave  <= '0;
            s3_duty  <= '0;
            s3_gain_voice <= '0;
            s3_gain_left  <= '0;
            s3_gain_right <= '0;
            s3_cascade  <= 1'b0;
            s3_filter_mode <= '0;
            s3_reso_att <= 16'hffff;
            s3_ic1eq1 <= '0;
            s3_ic2eq1 <= '0;
            s3_ic1eq2 <= '0;
            s3_ic2eq2 <= '0;
        end else begin
            s3_phase_inc_lut <= phase_lut[eff_pitch[9:0]];
            s3_svf_fc_lut     <= svf_fc_lut[eff_fc[9:0]];
            s3_q1_lut    <= q1_lut[eff_reso[9:6]];
            s3_reso_oct  <= eff_reso[13:10];
            s3_valid   <= s2_valid;
            s3_idx   <= s2_idx;
            s3_phase <= s2_phase;
            s3_pitch_oct <= eff_pitch[13:10];
            s3_fc_oct    <= eff_fc[13:10];
            s3_wave  <= s2_wave;
            s3_duty  <= eff_duty;
            s3_gain_voice <= s2_gain_voice;
            s3_gain_left  <= s2_gain_left;
            s3_gain_right <= s2_gain_right;
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
    assign k     = $signed({20'd0, s3_svf_fc_lut}) <<< (3 + s3_fc_oct);
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
    // oscillator sample down as resonance rises so the 24 dB/oct
    // cascade never overdrives its internal +-8 guardrail (sat_q414).
    // Register-then-multiply: S3B registers osc + the (cascade-gated) atten
    // and every SVF operand; S3C multiplies. Keeps the osc_core->reg
    // critical path intact (no combinational mult in it). A single section (12
    // dB/oct) never overdrives, so its atten is unity (0xffff).
    //----------------------------------------------------------------
    // S3B registers the ADVANCED PHASE (and duty/wave alongside it); the
    // waveform is generated from the registered value in S3B->S3C.
    logic               s3b_valid;   logic [VW-1:0] s3b_idx;
    logic [15:0] s3b_att;
    logic signed [35:0] s3b_k;     logic signed [17:0] s3b_q1;
    logic signed [35:0] s3b_ic1eq1, s3b_ic2eq1, s3b_ic1eq2, s3b_ic2eq2;
    logic               s3b_cascade;  logic [1:0] s3b_filter_mode;
    logic signed [23:0] s3b_phase;
    logic signed [17:0] s3b_gain_voice, s3b_gain_left, s3b_gain_right;
    logic signed [23:0] s3b_duty;  logic [1:0] s3b_wave;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3b_valid<=1'b0; s3b_idx<='0; s3b_att<='0;
            s3b_k<='0; s3b_q1<='0; s3b_ic1eq1<='0; s3b_ic2eq1<='0;
            s3b_ic1eq2<='0; s3b_ic2eq2<='0; s3b_cascade<=1'b0; s3b_filter_mode<='0;
            s3b_phase<='0; s3b_gain_voice<='0; s3b_gain_left<='0; s3b_gain_right<='0;
            s3b_duty<='0; s3b_wave<='0;
        end else begin
            s3b_valid<=s3_valid; s3b_idx<=s3_idx;
            s3b_att<=s3_reso_att; s3b_k<=k; s3b_q1<=q1_decoded;
            s3b_ic1eq1<=s3_ic1eq1; s3b_ic2eq1<=s3_ic2eq1;
            s3b_ic1eq2<=s3_ic1eq2; s3b_ic2eq2<=s3_ic2eq2;
            s3b_cascade<=s3_cascade; s3b_filter_mode<=s3_filter_mode;
            s3b_phase<=phase_next; s3b_gain_voice<=s3_gain_voice;
            s3b_gain_left<=s3_gain_left; s3b_gain_right<=s3_gain_right;
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
    logic signed [23:0] s3c_phase;
    logic signed [35:0] s3c_gain_left, s3c_gain_right;   // voice × channel, Q8.28
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3c_valid<=1'b0; s3c_idx<='0; s3c_osc<='0; s3c_att<='0;
            s3c_k<='0; s3c_q1<='0;
            s3c_ic1eq1<='0; s3c_ic2eq1<='0; s3c_ic1eq2<='0; s3c_ic2eq2<='0;
            s3c_cascade<=1'b0; s3c_filter_mode<='0; s3c_phase<='0; s3c_gain_left<='0; s3c_gain_right<='0;
        end else begin
            s3c_valid<=s3b_valid; s3c_idx<=s3b_idx;
            s3c_osc <= osc_sample; s3c_att <= s3b_att;
            s3c_k<=s3b_k; s3c_q1<=s3b_q1;
            s3c_ic1eq1<=s3b_ic1eq1; s3c_ic2eq1<=s3b_ic2eq1;
            s3c_ic1eq2<=s3b_ic1eq2; s3c_ic2eq2<=s3b_ic2eq2;
            s3c_cascade<=s3b_cascade; s3c_filter_mode<=s3b_filter_mode;
            s3c_phase<=s3b_phase;
            s3c_gain_left  <= s3b_gain_voice * s3b_gain_left;      // multiply only
            s3c_gain_right <= s3b_gain_voice * s3b_gain_right;
        end
    end

    //----------------------------------------------------------------
    // S3D -- the attenuation multiply, on REGISTERED operands. It sits
    // one stage after the waveform stage so that no cycle chains the
    // waveform mux into a DSP. The state writeback lands 25 cycles
    // after the read, against a 256-slot half, so read and write still
    // cannot collide.
    //----------------------------------------------------------------
    // A product of two Q4.14 gains is Q8.28; back to Q4.14, clamped.
    function automatic logic signed [17:0] gain_of(input logic signed [35:0] product);
        logic signed [21:0] scaled;
        scaled = 22'(product >>> 14);
        if (scaled > 22'sd131071) begin
            gain_of = 18'sd131071;
        end else if (scaled < -22'sd131072) begin
            gain_of = -18'sd131072;
        end else begin
            gain_of = scaled[17:0];
        end
    endfunction

    wire signed [35:0] osc_mul = s3c_osc * $signed({1'b0, s3c_att});
    logic               s3d_valid;   logic [VW-1:0] s3d_idx;
    logic signed [17:0] s3d_osc;
    logic signed [35:0] s3d_k;     logic signed [17:0] s3d_q1;
    logic signed [35:0] s3d_ic1eq1, s3d_ic2eq1, s3d_ic1eq2, s3d_ic2eq2;
    logic               s3d_cascade;  logic [1:0] s3d_filter_mode;
    logic signed [23:0] s3d_phase;
    logic signed [17:0] s3d_gain_left, s3d_gain_right;   // Q4.14, clamped
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3d_valid<=1'b0; s3d_idx<='0; s3d_osc<='0; s3d_k<='0; s3d_q1<='0;
            s3d_ic1eq1<='0; s3d_ic2eq1<='0; s3d_ic1eq2<='0; s3d_ic2eq2<='0;
            s3d_cascade<=1'b0; s3d_filter_mode<='0; s3d_phase<='0; s3d_gain_left<='0; s3d_gain_right<='0;
        end else begin
            s3d_valid<=s3c_valid; s3d_idx<=s3c_idx;
            s3d_osc <= 18'($signed(osc_mul >>> 16));
            s3d_k<=s3c_k; s3d_q1<=s3c_q1;
            s3d_ic1eq1<=s3c_ic1eq1; s3d_ic2eq1<=s3c_ic2eq1;
            s3d_ic1eq2<=s3c_ic1eq2; s3d_ic2eq2<=s3c_ic2eq2;
            s3d_cascade<=s3c_cascade; s3d_filter_mode<=s3c_filter_mode;
            s3d_phase<=s3c_phase;
            s3d_gain_left  <= gain_of(s3c_gain_left);
            s3d_gain_right <= gain_of(s3c_gain_right);
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
    wire signed [17:0] s9_sample;
    wire signed [23:0] s9_phase;
    wire signed [35:0] s9_ic1eq1n, s9_ic2eq1n, s9_ic1eq2n, s9_ic2eq2n;
    wire signed [17:0] s9_gain_l, s9_gain_r;

    svf_tpt #(.IDXW(VW)) u_svf (
        .clk(clk), .rst_n(rst_n),
        .in_valid(s3d_valid), .in_idx(s3d_idx),
        .in_osc(s3d_osc), .in_k(s3d_k), .in_q1(s3d_q1),
        .in_ic1eq1(s3d_ic1eq1), .in_ic2eq1(s3d_ic2eq1),
        .in_ic1eq2(s3d_ic1eq2), .in_ic2eq2(s3d_ic2eq2),
        .in_cascade(s3d_cascade), .in_filter_mode(s3d_filter_mode),
        .in_phase(s3d_phase), .in_gain_l(s3d_gain_left), .in_gain_r(s3d_gain_right),
        .out_valid(s9_valid), .out_idx(s9_idx), .out_sample(s9_sample),
        .out_ic1eq1n(s9_ic1eq1n), .out_ic2eq1n(s9_ic2eq1n),
        .out_ic1eq2n(s9_ic1eq2n), .out_ic2eq2n(s9_ic2eq2n),
        .out_phase(s9_phase), .out_gain_l(s9_gain_l), .out_gain_r(s9_gain_r)
    );

    //----------------------------------------------------------------
    // S10 — gain multiply on the SVF's registered outputs  (DSP)
    //----------------------------------------------------------------
    logic        s10_valid;
    logic [VW-1:0] s10_idx;
    logic signed [21:0] s10_outl, s10_outr;   // Q4.14 × gain up to ±8: 22 bits, no clamp
    logic signed [23:0] s10_phase;
    logic signed [35:0] s10_ic1eq1n, s10_ic2eq1n, s10_ic1eq2n, s10_ic2eq2n;

    logic signed [35:0] prod_l, prod_r;
    always_comb begin
        prod_l = s9_sample * s9_gain_l;
        prod_r = s9_sample * s9_gain_r;
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
            s10_valid  <= s9_valid;
            s10_idx  <= s9_idx;
            s10_outl <= 22'(prod_l >>> 14);
            s10_outr <= 22'(prod_r >>> 14);
            s10_phase <= s9_phase;
            s10_ic1eq1n <= s9_ic1eq1n;
            s10_ic2eq1n <= s9_ic2eq1n;
            s10_ic1eq2n <= s9_ic1eq2n;
            s10_ic2eq2n <= s9_ic2eq2n;
        end
    end

    //----------------------------------------------------------------
    // S11 — mix accumulate + state writeback
    //
    // Mixdown headroom: 256 partials × Q4.14 (±8.0) sums to ±2048 in a
    // 26-bit Q4.14 accumulator (12 integer bits, ±2048) — marginal by
    // design exactly as the Q2.16 era was (256 × ±2.0 vs ±512). The
    // output limiter (sat24) converts Q4.14 → Q0.24 (<< 10) and clips
    // only in the pathological all-aligned-at-the-rail case; overall
    // loudness is set by the per-partial UQ4.4 gains: −2 bits of audio
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
                mix_acc_l <= mix_acc_l + {{4{s10_outl[21]}}, s10_outl};
                mix_acc_r <= mix_acc_r + {{4{s10_outr[21]}}, s10_outr};
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
