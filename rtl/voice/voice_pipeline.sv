//--------------------------------------------------------------------
// voice_pipeline.sv — 256-voice SCMO pipeline ("the drum" voice section)
//
// One voice enters the pipeline every sysclk cycle for 256 cycles of
// each sample period (drum slot 0..255).  Every cycle, every stage
// processes a different voice: stage Sk at drum slot t holds the voice
// that entered at slot t-k.  The pipeline occupies 256 + 14 - 1 = 269
// contiguous slots (~26% of the 1024-slot drum rotation).
//
// Stage map:
//   S1  state/param RAM read data available (address issued at S0)
//   S2  issue phase-delta + SVF-K LUT reads
//   S3  LUT data → delta, K, q1; phase_next; oscillator waveform
//   S4  SVF1 A:  m1 = K*ic1eq1,  m2 = q1*ic1eq1     (DSP)
//   S5  SVF1 B1: lp1/hp1 adder tree
//   S5B SVF1 B2: m3 = K*hp1 on registered hp1        (DSP)
//   S6  SVF1 C:  bp1, new states, filter-1 output
//   S7  SVF2 A:  m4 = K*ic1eq2,  m5 = q1*ic1eq2     (DSP)
//   S8  SVF2 B1: lp2/hp2 adder tree
//   S8B SVF2 B2: m6 = K*hp2 on registered hp2        (DSP)
//   S9  SVF2 C:  bp2, new states, filter-2 output, voice output
//   S10 attenuation: log-gain decode + stereo multiply   (DSP)
//   S11 mix accumulate + state writeback
//
// S5B/S8B exist because chaining the adder tree into the 36x36 multiply
// violated setup on real silicon at 98.304 MHz for long-carry operand
// patterns (low cutoffs) — sparse single-sample corruption, gone at
// half clock — which nextpnr's approximate timing model did not flag.
// Rule: a stage is adds-only or multiply-only, never both chained.
//
// Number formats (design doc):
//   phase      UQ0.24  (24-bit)
//   audio      Q2.16   (18-bit)
//   SVF states Q8.28   (36-bit)
//   pitch/fc   UQ4.10  (14-bit)
//   gain       UQ4.4   (8-bit, log: 6 dB int steps + 0.375 dB frac)
//
// State RAM is semi dual-port: read address is issued with the voice
// entering at S0, writeback happens 13 cycles later — the read
// and write addresses can never collide.
//--------------------------------------------------------------------
`default_nettype none
module voice_pipeline #(
    parameter int NUM_VOICES = 256
) (
    input  logic           clk,
    input  logic           rst_n,

    input  logic [9:0]     slot,
    input  logic           voice_enter,
    input  logic           sample_tick,

    output logic signed [23:0] mix_left,    // Q0.24, updated at sample_tick
    output logic signed [23:0] mix_right
);

    localparam int VW = $clog2(NUM_VOICES);   // voice index width

    //----------------------------------------------------------------
    // LUT ROMs (combinational reads)
    //----------------------------------------------------------------
    reg [23:0] phase_lut [0:1023];     // osc phase delta, one octave
    reg [15:0] k_lut     [0:1023];     // SVF K mantissa, one octave
    reg [16:0] att_lut   [0:15];       // log-gain fractional part

    initial begin
        $readmemh("voice/phase_lut.hex", phase_lut);
        $readmemh("voice/svf_k_lut.hex", k_lut);
        $readmemh("voice/att_lut.hex", att_lut);
    end

    //----------------------------------------------------------------
    // Per-voice internal state RAM — semi dual-port
    // read address: entering voice (S0), write: 13 cycles later
    //----------------------------------------------------------------
    reg signed [23:0] phase_ram  [0:NUM_VOICES-1];
    reg signed [35:0] ic1eq1_ram [0:NUM_VOICES-1];
    reg signed [35:0] ic2eq1_ram [0:NUM_VOICES-1];
    reg signed [35:0] ic1eq2_ram [0:NUM_VOICES-1];
    reg signed [35:0] ic2eq2_ram [0:NUM_VOICES-1];

    //----------------------------------------------------------------
    // Per-voice parameter RAM — read-only this milestone
    // (SPI write port arrives with the control banks; init below)
    //
    //   p0[13:0]  pitch UQ4.10     p0[15:14] waveform
    //   p1[23:0]  duty  Q0.24 signed
    //   p2[13:0]  fc    UQ4.10     p2[31:14] q1 Q2.16 signed
    //   p3[7:0]   gain L UQ4.4     p3[15:8] gain R UQ4.4
    //   p3[16]    24 dB mode       p3[18:17] filter type
    //----------------------------------------------------------------
    reg [35:0] p0_ram [0:NUM_VOICES-1];
    reg [35:0] p1_ram [0:NUM_VOICES-1];
    reg [35:0] p2_ram [0:NUM_VOICES-1];
    reg [35:0] p3_ram [0:NUM_VOICES-1];

    initial begin
        $readmemh("voice/test_patch_p0.hex", p0_ram);
        $readmemh("voice/test_patch_p1.hex", p1_ram);
        $readmemh("voice/test_patch_p2.hex", p2_ram);
        $readmemh("voice/test_patch_p3.hex", p3_ram);
    end

    // State RAMs start at zero (power-on init; also keeps X out of sim)
    integer i0;
    initial begin
        for (i0 = 0; i0 < NUM_VOICES; i0 = i0 + 1) begin
            phase_ram[i0]  = '0;
            ic1eq1_ram[i0] = '0;
            ic2eq1_ram[i0] = '0;
            ic1eq2_ram[i0] = '0;
            ic2eq2_ram[i0] = '0;
        end
    end

    //----------------------------------------------------------------
    // S0/S1 — RAM reads (address = voice entering this cycle)
    //
    // Sync-only process: yosys memory inference (BSRAM read port).
    // Read data validity is gated by s1_act, so no reset is needed.
    //----------------------------------------------------------------
    logic [VW-1:0] raddr;
    assign raddr = voice_enter ? slot[VW-1:0] : '0;

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

    logic [35:0] p0_rd, p1_rd, p2_rd, p3_rd;
    always_comb begin
        p0_rd = p0_ram[raddr];
        p1_rd = p1_ram[raddr];
        p2_rd = p2_ram[raddr];
        p3_rd = p3_ram[raddr];
    end

    always_ff @(posedge clk) begin
        s1_phase  <= phase_ram[raddr];
        s1_ic1eq1 <= ic1eq1_ram[raddr];
        s1_ic2eq1 <= ic2eq1_ram[raddr];
        s1_ic1eq2 <= ic1eq2_ram[raddr];
        s1_ic2eq2 <= ic2eq2_ram[raddr];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_act   <= 1'b0;
            s1_idx   <= '0;
            s1_pitch <= '0;
            s1_wave  <= '0;
            s1_duty  <= '0;
            s1_fc    <= '0;
            s1_q1    <= '0;
            s1_gl    <= '0;
            s1_gr    <= '0;
            s1_dual  <= 1'b0;
            s1_ftype <= '0;
        end else begin
            s1_act   <= voice_enter;
            s1_idx   <= slot[VW-1:0];
            s1_pitch <= p0_rd[13:0];
            s1_wave  <= p0_rd[15:14];
            s1_duty  <= p1_rd[23:0];
            s1_fc    <= p2_rd[13:0];
            s1_q1    <= p2_rd[31:14];
            s1_gl    <= p3_rd[7:0];
            s1_gr    <= p3_rd[15:8];
            s1_dual  <= p3_rd[16];
            s1_ftype <= p3_rd[18:17];
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
            s3_delta_lut <= phase_lut[s2_pitch[9:0]];
            s3_k_lut     <= k_lut[s2_fc[9:0]];
            s3_act   <= s2_act;
            s3_idx   <= s2_idx;
            s3_phase <= s2_phase;
            s3_pitch_oct <= s2_pitch[13:10];
            s3_fc_oct    <= s2_fc[13:10];
            s3_wave  <= s2_wave;
            s3_duty  <= s2_duty;
            s3_q1    <= s2_q1;
            s3_gl    <= s2_gl;
            s3_gr    <= s2_gr;
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
            s4_act  <= s3_act;
            s4_idx  <= s3_idx;
            s4_m1   <= k * s3_ic1eq1;
            s4_m2   <= (s3_q1 <<< 12) * s3_ic1eq1;   // Q2.16 → Q8.28
            s4_osc  <= osc_sample;
            s4_phase <= s3_phase + delta;
            s4_k    <= k;
            s4_q1   <= s3_q1;
            s4_ic1eq1 <= s3_ic1eq1;
            s4_ic2eq1 <= s3_ic2eq1;
            s4_ic1eq2 <= s3_ic1eq2;
            s4_ic2eq2 <= s3_ic2eq2;
            s4_gl   <= s3_gl;
            s4_gr   <= s3_gr;
            s4_dual <= s3_dual;
            s4_ftype <= s3_ftype;
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
    // S9 — SVF2 stage C: bp2, new states, filter-2 output, voice out
    //----------------------------------------------------------------
    logic        s9_act;
    logic [VW-1:0] s9_idx;
    logic signed [17:0] s9_voice;          // Q2.16
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
            s9_voice <= '0;
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
            s9_voice <= s8b_dual ? sat_q216(f2_36) : s8b_f1;
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
    // S10 — attenuation: log-gain decode + stereo multiply  (DSP)
    //
    //   gain UQ4.4: lin = att_lut[frac] >>> int
    //   att_lut[i] = 2^(-i/16) in UQ0.16 → 6 dB per int step,
    //   0.375 dB per frac step.
    //----------------------------------------------------------------
    logic        s10_act;
    logic [VW-1:0] s10_idx;
    logic signed [17:0] s10_outl, s10_outr;
    logic signed [23:0] s10_phase;
    logic signed [35:0] s10_ic1eq1n, s10_ic2eq1n, s10_ic1eq2n, s10_ic2eq2n;

    logic signed [17:0] lin_l, lin_r;
    always_comb begin
        lin_l = 18'($signed({1'b0, att_lut[s9_gl[3:0]]})) >>> s9_gl[7:4];
        lin_r = 18'($signed({1'b0, att_lut[s9_gr[3:0]]})) >>> s9_gr[7:4];
    end

    logic signed [34:0] prod_l, prod_r;
    always_comb begin
        prod_l = s9_voice * lin_l;
        prod_r = s9_voice * lin_r;
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
            s10_act  <= s9_act;
            s10_idx  <= s9_idx;
            s10_outl <= prod_l >>> 16;
            s10_outr <= prod_r >>> 16;
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
    // Mixdown headroom: 256 voices × Q2.16 (±2.0) needs 8 guard bits,
    // so the accumulator is 26-bit and can never overflow even with
    // all voices coherent and full-scale.  The output limiter (sat24)
    // converts Q2.16 → Q0.24 (<< 8) and clips only in the pathological
    // all-256-voices-aligned case; overall loudness is set by the
    // per-voice UQ4.4 gains (test patch: -36 dB/voice → 8 unison voices
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
