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
//   S3B register phase_next / the cutoff word and octave / q1 / duty / wave
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
//              rail, the voice's gain the fraction of a 60 dB span and
//              the channel's gains linear (see the effective parameters)
//
// State RAM is semi dual-port: the read address is issued with the
// partial at F3, writeback happens about 25 cycles later — the read
// and write addresses can never collide.
//
// Reset (#309): in the pipeline stages only the *_valid registers have
// one. A stage's datapath register is meaningful only beside its valid
// bit, so it is a plain flip-flop with no reset and no enable: a reset
// there costs the reset net's fanout and keeps a fixed delay out of
// memory, and buys nothing. The mix and limiter registers keep theirs:
// they are state, and the limiter's gain must start defined.
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

    // The data stream's view of a sink word (the probe's address, #236):
    // the last port is addressed by a partial on odd slots only, so on
    // every other clock it reads the probe's word, as the partials would.
    input  logic [9:0]     probe_address,
    output logic [17:0]    probe_word,

    output logic signed [25:0] mix_left,    // Q4.14 with 8 guard bits: the
                                             // raw stereo sum, published at
                                             // sample_tick and held for the
                                             // sample; the master limiter
                                             // (master_limiter.sv) takes it
    output logic signed [25:0] mix_right
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
    reg signed [15:0] sine_lut [0:1023];   // the sine wave, Q2.16, one
                                       // entry per value of the top ten
                                       // phase bits (scripts/gen_sine_lut.py);
                                       // BSRAM, read at the S3B edge

    initial begin
        $readmemh("dsp/phase_lut.hex", phase_lut);
        $readmemh("dsp/svf_fc_lut.hex", svf_fc_lut);
        $readmemh("dsp/q1_lut.hex", q1_lut);
        $readmemh("dsp/reso_att_lut.hex", reso_att_lut);
        $readmemh("dsp/sine_lut.hex", sine_lut);
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
    // Every pointer starts at the sink area's zero word, so that a partial
    // nobody has pointed anywhere is silent.
    logic [POINTER_RAM_W-1:0] unpointed_entry;
    initial begin
        unpointed_entry = '0;
        for (int position = 0; position < synth_pkg::POINTERS_PER_PARTIAL; position++) begin
            unpointed_entry[position * synth_pkg::POINTER_W +: synth_pkg::POINTER_W]
                = synth_pkg::POINTER_ZERO;
        end
        for (int partial = 0; partial < NUM_PARTIALS; partial++) begin
            pointer_block_0[partial] = unpointed_entry[35:0];
            pointer_block_1[partial] = unpointed_entry[71:36];
            pointer_block_2[partial] = unpointed_entry[107:72];
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
    // the second group's ports, read in F2; the rest are first-group ports, and the last of
    // them reads the probe's word in its other clocks
    localparam int SECOND_GROUP_PORTS = synth_pkg::POINTERS_PER_PARTIAL - synth_pkg::SINK_READ_PORTS;
    localparam int PROBE_PORT = synth_pkg::SINK_READ_PORTS - 1;
    if (PROBE_PORT < SECOND_GROUP_PORTS) $error("partial_pipeline: the probe's port must be a first-group port");
    logic [synth_pkg::POINTER_W-1:0] f2_pointer [SECOND_GROUP_PORTS];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) f1_valid <= 1'b0;
        else        f1_valid <= partial_start;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) f2_valid <= 1'b0;
        else        f2_valid <= f1_valid;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) f3_valid <= 1'b0;
        else        f3_valid <= f2_valid;
    end
    always_ff @(posedge clk) begin
        f1_idx <= partial_index;
        f2_idx <= f1_idx;
        f3_idx <= f2_idx;
    end

    // F1: the first six words. F2: the last four, with the pointers kept
    // from F1. A partial is in F1 on odd slots and in F2 on even ones, so
    // the ports never serve two partials at once. A port no partial is
    // using is parked on the zero word, the row nothing writes: the sink
    // area's write takes a port's read for a clock (csp_sink_area), and
    // the firmware's words take one of the page the partials read, in
    // the pass's window, when every port is parked.
    always_ff @(posedge clk) begin
        for (int second = 0; second < SECOND_GROUP_PORTS; second++) begin
            f2_pointer[second] <= pointer_of(f1_entry, synth_pkg::SINK_READ_PORTS + second);
        end
    end

    always_comb begin
        for (int port = 0; port < synth_pkg::SINK_READ_PORTS; port++) begin
            if (f1_valid) begin
                sink_read_address[port] = 10'(pointer_of(f1_entry, port));
            end else if (port < SECOND_GROUP_PORTS && f2_valid) begin
                sink_read_address[port] = 10'(f2_pointer[port]);
            end else if (port == PROBE_PORT) begin
                sink_read_address[port] = probe_address;
            end else begin
                sink_read_address[port] = synth_pkg::POINTER_ZERO;
            end
        end
    end

    // the probe's word: the one the probe's port read, which is the clock after any address
    // that was not a partial's
    always_ff @(posedge clk) begin
        if (!f2_valid) probe_word <= sink_read_data[PROBE_PORT];
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
        if (!rst_n) s1_valid <= 1'b0;
        else        s1_valid <= f3_valid;
    end
    always_ff @(posedge clk) begin
        s1_idx   <= f3_idx;
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
        if (!rst_n) s2_valid <= 1'b0;
        else        s2_valid <= s1_valid;
    end
    always_ff @(posedge clk) begin
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

    // The voice's gain: the word IS the linear gain (#176) — Q4.14, the
    // envelope's level × the velocity's amount as the control program
    // leaves it — clamped at unity, silent at zero and below (a released
    // level parks a step under zero). Every gain path is a multiply: this
    // word × the channel's left and right gains at S3C. No curve lives
    // here; a loudness law is the firmware's to compute, once, host-side.
    wire signed [17:0] gain_unity_clamped =
        (s2_gain_voice > 18'sd16384) ? 18'sd16384 : s2_gain_voice;
    wire gain_mute = s2_gain_voice <= 18'sd0;

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
    logic signed [17:0] s3_gain_voice; // the voice's linear gain, clamped at unity
    logic        s3_gain_mute;
    logic signed [17:0] s3_gain_left, s3_gain_right;
    logic        s3_cascade;
    logic [1:0]  s3_filter_mode;
    logic [15:0] s3_reso_att;   // input-atten gain (UQ0.16)
    logic signed [35:0] s3_ic1eq1, s3_ic2eq1, s3_ic1eq2, s3_ic2eq2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) s3_valid <= 1'b0;
        else        s3_valid <= s2_valid;
    end
    always_ff @(posedge clk) begin
        s3_phase_inc_lut <= phase_lut[eff_pitch[9:0]];
        s3_svf_fc_lut     <= svf_fc_lut[eff_fc[9:0]];
        s3_q1_lut    <= q1_lut[eff_reso[9:6]];
        s3_reso_oct  <= eff_reso[13:10];
        s3_idx   <= s2_idx;
        s3_phase <= s2_phase;
        s3_pitch_oct <= eff_pitch[13:10];
        s3_fc_oct    <= eff_fc[13:10];
        s3_wave  <= s2_wave;
        s3_duty  <= eff_duty;
        s3_gain_voice    <= gain_unity_clamped;
        s3_gain_mute     <= gain_mute;
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

    // S3 combinational datapath
    logic signed [23:0] phase_inc;
    logic signed [17:0] osc_sample;

    assign phase_inc = $signed(s3_phase_inc_lut) >>> (11 - s3_pitch_oct);
    // The cutoff coefficient K = word <<< (3 + octave) in Q8.28 is formed
    // in the filter: its g*state products take the 16-bit word and shift
    // the product by the octave instead (svf_tpt.sv, #428), the same bits
    // for two multipliers where K's full width took four. K is NOT
    // narrowed: the LUT+shift expands to ~22+ bits of real precision,
    // needed later for the noise oscillator and whistling-filter melodies.
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

    // The voice gain as the S3C multiply takes it: the clamped word, or
    // zero for a silent voice; registered into S3B.
    wire signed [17:0] gain_decoded = s3_gain_mute ? 18'sd0 : s3_gain_voice;

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
    logic [15:0] s3b_fc_mantissa;  logic [3:0] s3b_fc_oct;  logic signed [17:0] s3b_q1;
    logic signed [35:0] s3b_ic1eq1, s3b_ic2eq1, s3b_ic1eq2, s3b_ic2eq2;
    logic               s3b_cascade;  logic [1:0] s3b_filter_mode;
    logic signed [23:0] s3b_phase;
    logic signed [17:0] s3b_gain_voice, s3b_gain_left, s3b_gain_right;
    logic signed [23:0] s3b_duty;  logic [1:0] s3b_wave;
    logic signed [24:0] s3b_pulse_max, s3b_pulse_min;   // the pulse's DC-corrected levels (osc_core: 2^23-1 - duty, -2^23 - duty)
    logic signed [15:0] s3b_sine;      // the sine at s3b_phase, the table's clocked read
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) s3b_valid <= 1'b0;
        else        s3b_valid <= s3_valid;
    end
    always_ff @(posedge clk) begin
        s3b_idx<=s3_idx;
        s3b_att<=s3_reso_att; s3b_fc_mantissa<=s3_svf_fc_lut; s3b_fc_oct<=s3_fc_oct; s3b_q1<=q1_decoded;
        s3b_ic1eq1<=s3_ic1eq1; s3b_ic2eq1<=s3_ic2eq1;
        s3b_ic1eq2<=s3_ic1eq2; s3b_ic2eq2<=s3_ic2eq2;
        s3b_cascade<=s3_cascade; s3b_filter_mode<=s3_filter_mode;
        s3b_phase<=phase_next; s3b_gain_voice<=gain_decoded;
        s3b_gain_left<=s3_gain_left; s3b_gain_right<=s3_gain_right;
        s3b_duty<=s3_duty; s3b_wave<=s3_wave;
        s3b_pulse_max <= 25'sd8388607  - 25'(s3_duty);
        s3b_pulse_min <= -25'sd8388608 - 25'(s3_duty);
        s3b_sine <= sine_lut[phase_next[23:14]];
    end

    // Waveform generation stands alone in its own stage, driven by the
    // REGISTERED phase (the sine read in block RAM alongside it): a
    // compare, a fold and a 4:1 mux, which must not be chained behind
    // the phase adder.
    osc_core u_osc (
        .phase_next (s3b_phase),
        .duty       (s3b_duty),
        .pulse_max   (s3b_pulse_max),
        .pulse_min   (s3b_pulse_min),
        .wave       (s3b_wave),
        .sine       (s3b_sine),
        .sample_out (osc_sample)
    );

    // S3C registers the WAVEFORM (was: the attenuation product). The
    // multiply moves to S3D so nothing chains a mux into a DSP.
    logic               s3c_valid;   logic [VW-1:0] s3c_idx;
    logic signed [17:0] s3c_osc;   logic [15:0] s3c_att;
    logic [15:0] s3c_fc_mantissa;  logic [3:0] s3c_fc_oct;  logic signed [17:0] s3c_q1;
    logic signed [35:0] s3c_ic1eq1, s3c_ic2eq1, s3c_ic1eq2, s3c_ic2eq2;
    logic               s3c_cascade;  logic [1:0] s3c_filter_mode;
    logic signed [23:0] s3c_phase;
    logic signed [35:0] s3c_gain_left, s3c_gain_right;   // voice × channel, Q8.28
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) s3c_valid <= 1'b0;
        else        s3c_valid <= s3b_valid;
    end
    always_ff @(posedge clk) begin
        s3c_idx<=s3b_idx;
        s3c_osc <= osc_sample; s3c_att <= s3b_att;
        s3c_fc_mantissa<=s3b_fc_mantissa; s3c_fc_oct<=s3b_fc_oct; s3c_q1<=s3b_q1;
        s3c_ic1eq1<=s3b_ic1eq1; s3c_ic2eq1<=s3b_ic2eq1;
        s3c_ic1eq2<=s3b_ic1eq2; s3c_ic2eq2<=s3b_ic2eq2;
        s3c_cascade<=s3b_cascade; s3c_filter_mode<=s3b_filter_mode;
        s3c_phase<=s3b_phase;
        s3c_gain_left  <= s3b_gain_voice * s3b_gain_left;      // multiply only
        s3c_gain_right <= s3b_gain_voice * s3b_gain_right;
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
    logic [15:0] s3d_fc_mantissa;  logic [3:0] s3d_fc_oct;  logic signed [17:0] s3d_q1;
    logic signed [35:0] s3d_ic1eq1, s3d_ic2eq1, s3d_ic1eq2, s3d_ic2eq2;
    logic               s3d_cascade;  logic [1:0] s3d_filter_mode;
    logic signed [23:0] s3d_phase;
    logic signed [17:0] s3d_gain_left, s3d_gain_right;   // Q4.14, clamped
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) s3d_valid <= 1'b0;
        else        s3d_valid <= s3c_valid;
    end
    always_ff @(posedge clk) begin
        s3d_idx<=s3c_idx;
        s3d_osc <= 18'($signed(osc_mul >>> 16));
        s3d_fc_mantissa<=s3c_fc_mantissa; s3d_fc_oct<=s3c_fc_oct; s3d_q1<=s3c_q1;
        s3d_ic1eq1<=s3c_ic1eq1; s3d_ic2eq1<=s3c_ic2eq1;
        s3d_ic1eq2<=s3c_ic1eq2; s3d_ic2eq2<=s3c_ic2eq2;
        s3d_cascade<=s3c_cascade; s3d_filter_mode<=s3c_filter_mode;
        s3d_phase<=s3c_phase;
        s3d_gain_left  <= gain_of(s3c_gain_left);
        s3d_gain_right <= gain_of(s3c_gain_right);
    end

    //----------------------------------------------------------------
    // SVF core (TPT), stages S4..S9.
    //   g = K>>1 (= pi*fc/fs), R2 = q1, h = 1/D via reciprocal LUT.
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
        .in_osc(s3d_osc), .in_k_mantissa(s3d_fc_mantissa), .in_k_octave(s3d_fc_oct), .in_q1(s3d_q1),
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
        if (!rst_n) s10_valid <= 1'b0;
        else        s10_valid <= s9_valid;
    end
    always_ff @(posedge clk) begin
        s10_idx  <= s9_idx;
        s10_outl <= 22'(prod_l >>> 14);
        s10_outr <= 22'(prod_r >>> 14);
        s10_phase <= s9_phase;
        s10_ic1eq1n <= s9_ic1eq1n;
        s10_ic2eq1n <= s9_ic2eq1n;
        s10_ic1eq2n <= s9_ic1eq2n;
        s10_ic2eq2n <= s9_ic2eq2n;
    end

    //----------------------------------------------------------------
    // S11 — mix accumulate + state writeback
    //
    // Mixdown headroom: 256 partials × Q4.14 (±8.0) sums to ±2048 in a
    // 26-bit Q4.14 accumulator (12 integer bits, ±2048) — marginal by
    // design exactly as the Q2.16 era was (256 × ±2.0 vs ±512). The
    // sum is published raw at the tick; the master limiter and the
    // Q4.14 → Q0.24 clip are the next block (master_limiter.sv, #416).
    // Overall loudness is set by the per-partial UQ4.4 gains: −2 bits
    // of audio scale cancel the +2 bits of conversion shift there.
    //----------------------------------------------------------------
    logic signed [25:0] mix_acc_l, mix_acc_r;   // Q4.14 audio + 8 guard bits

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mix_acc_l <= '0;
            mix_acc_r <= '0;
            mix_left  <= '0;
            mix_right <= '0;
        end else begin
            if (sample_tick) begin
                // sample boundary: publish the finished sum, start
                // accumulating the next sample
                mix_left  <= mix_acc_l;
                mix_right <= mix_acc_r;
                mix_acc_l <= '0;
                mix_acc_r <= '0;
            end else if (s10_valid) begin
                mix_acc_l <= mix_acc_l + {{4{s10_outl[21]}}, s10_outl};
                mix_acc_r <= mix_acc_r + {{4{s10_outr[21]}}, s10_outr};
            end
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
