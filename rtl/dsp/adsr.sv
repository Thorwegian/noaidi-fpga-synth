//------------------------------------------------------------------------
// adsr.sv -- the RC envelope, as its own module
//
// Copyright (C) 2026  Thor Johannes Hoeyer
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// The envelope is the one instruction with a real state machine, so it
// earns a module; the LFO is an adder and the SEND is a wire.
//
// THE RECURRENCE. RC for everything, and no LUTs for the ADSR.
// The level is a LINEAR AMPLITUDE in UQ12.14 across [25:0]; full scale
// 0x400000 is the gain bus's Q4.14 unity (0x4000) carrying eight extra
// fractional bits so a slow step does not truncate away. Every segment is
// the same recurrence,
//
//     y += (target - y) * k
//
// and the stage chooses nothing but the target and the rate. Sustain is the
// only straight line in the envelope, and it is straight because it is a
// FIXED POINT of that recurrence, not a special case.
//
// Attack charges toward 1.3x full scale and a comparator ends it at full
// scale -- the CEM3310 / SSM2056 trick. What you hear is the first 77% of an
// RC charge, which is convex, instead of the tail, which flattens into a soft
// attack nobody wants.
//
// RATES ARRIVE AS COEFFICIENTS. Firmware sends an 18-bit k per segment
// and this module multiplies by it and shifts by a FIXED K_SHIFT. It used to
// decode a mantissa and a variable barrel shift here, and that shifter -- a
// LUT mux tree feeding a fabric carry chain -- was the design's critical path
// -- it costs about 8 MHz of headroom, and placement moves it enough that
// seeds glitch audibly. Rate decoding is control-rate work; it belongs on
// the ESP32, which is where it lives.
//
// THE ARITHMETIC IS IN THE DSP BLOCKS, EXPLICITLY, because Gowin's DSP and
// ALU primitives have to be instantiated by hand: yosys will not infer
// them. /opt/oss-cad-suite/share/yosys/gowin/
// dsp_map.v carries exactly three techmap rules -- $__MUL9X9, $__MUL18X18,
// $__MUL36X36 -- and none for a fused cell, so no amount of rewriting the
// recurrence as an expression will ever produce one. Writing it as `delta * k`
// gave bare MULTs with the accumulate in fabric, which is where the carry
// chains came from. So the two stages are hand-instantiated:
//
//     ALU54D         delta = target - level
//     MULTALU36X18   DOUT  = k * delta + (level << K_SHIFT)
//     wiring         level_next = DOUT[K_SHIFT+25 : K_SHIFT]
//
// MULTADDALU18X18 is the wrong primitive here twice over: its A operands are
// 18 bits against a 26-bit level, and its mode-1 accumulator is a single value
// inside the block, which cannot hold per-envelope state for a datapath that
// is time-multiplexed across many envelopes. MULTALU36X18 takes the 36-bit
// operand and carries the state in on C, which is what this machine needs.
//
// The >>> K_SHIFT is bit-exact rather than approximate: `level << K_SHIFT` has
// K_SHIFT zero low bits, so arithmetically shifting the SUM right by K_SHIFT
// equals shifting the product and then adding, for both signs of delta.
// tb_dsp_char.sv checks that against Gowin's own model -- 249/249 exact
// against the fabric version, including both slowest and fastest coefficient
// and decay onto sustain from above and below.
//
// Wire format, MIRRORED IN app/main/patch.h -- change both or neither:
//
//   rates   [17:0] kA          [31:18] kD[13:0]
//   rates2  [3:0]  kD[17:14]   [21:4]  kR       [31:22] sustain
//
// Sustain arrives as a plain 10-bit level too. Only the linear decode is
// used; the log decode CFG[26] would select is never selected.
//
// PIPELINING. Subtract, then multiply-accumulate; each DSP registers its own
// output, so state_out lands TWO cycles after the inputs are presented and the
// caller must delay its state-write address to match. That is the same depth
// a fabric implementation needs -- measured, 2 clock edges -- so moving
// into the DSP blocks costs no re-alignment. An instruction is visited once
// per pass, 256 entries apart, so a delayed write can never race its own read.
//------------------------------------------------------------------------
`default_nettype none
module adsr #(
    parameter int K_SHIFT   = 24,     // firmware scales k by 2**K_SHIFT
    parameter int SUS_SHIFT = 12      // = ADSR_SUS_SHIFT in patch.h
) (
    input  wire        clk,
    input  wire        rst_n,

    // presented together, registered by the caller
    input  wire        step_en,      // advance this envelope now
    input  wire [27:0] state_in,     // {stage[1:0], level[25:0]}
    input  wire        gate,         // watched bus level > 0 = held
    input  wire [31:0] rates,        // kA and the low 14 bits of kD
    input  wire [31:0] rates2,       // the rest of kD, then kR and sustain

    // the envelope's contribution, combinational from state_in
    output wire signed [17:0] level_out,

    // next state, valid two cycles after step_en
    output wire [27:0] state_out,
    output wire        state_we
);
    localparam [1:0] AST_IDLE = 2'd0, AST_ATT = 2'd1,
                     AST_DEC  = 2'd2, AST_REL = 2'd3;
    localparam [25:0] ENV_FULL = 26'h400000;
    localparam [25:0] ENV_OVER = 26'h533333;   // 1.3 x full scale

    // Gowin's behavioural models all read `GSR.GSRO` as an UPWARD hierarchical
    // reference, so simulation needs an instance named literally GSR somewhere
    // up the hierarchy -- putting it here means no testbench has to know about
    // it. Simulation-only on purpose: in silicon the global set/reset network
    // is device infrastructure that the primitive is wired to implicitly, and
    // instantiating a second GSR in the synthesised design would fight the one
    // the tools already provide. The models are vendor code, so the Makefile
    // references them where the toolchain installs them rather than vendoring
    // a copy into a CERN-OHL-S tree.
`ifdef SIM_GOWIN_PRIM
    GSR GSR (.GSRI(1'b1));
`endif

    wire [1:0]  stage_prev = state_in[27:26];
    wire [25:0] level_prev = state_in[25:0];

    // The contribution. The caller computes (operand * DEPTH) >>> 16, so
    // "unity" for an operand is 0x10000 -- a depth of +8 octaves must then
    // move the bus by exactly +8 octaves. ENV_FULL is 2^22, so the level
    // shifts right by 6 to land on 2^16 at full scale.
    //
    // Taking level[24:8] here would land on 0x4000, the gain bus's
    // Q4.14 unity. Against this bus convention that makes every
    // envelope a quarter of its intended depth: a +8 octave envelope
    // moves the bus by 2.
    assign level_out = $signed({1'b0, level_prev[22:6]});

    // ---- which segment this step belongs to -----------------------------
    wire [1:0] stage_sel = !gate                  ? AST_REL
                         : (stage_prev == AST_ATT) ? AST_ATT
                         : (stage_prev == AST_DEC) ? AST_DEC
                         :                           AST_ATT;   // from idle

    // RETRIGGER. The gate is a LEVEL and the stage is this envelope's only
    // memory, so a voice stolen mid-release arrives here as AST_REL with a
    // non-zero level and the attack above continues FROM that level instead of
    // from silence -- audibly, an attack that starts part-way up and is much
    // shorter, because the attack charges toward 1.3x full scale. Chords
    // played in succession are the case that hits it: each chord's
    // note-offs leave releasing voices for the next chord to steal. A released envelope whose gate goes high again is a NEW NOTE, so
    // it starts from zero.
    //
    // AST_IDLE does not need this -- the release latches {AST_IDLE, 26'd0} on
    // arrival, so an idle envelope's level is already 0.
    //
    // Not fixed here, and deliberately: stealing a voice that is still HELD.
    // Its gate never drops, so nothing in the gateware can tell that apart from
    // the same note continuing; that one needs firmware to drop the gate for a
    // pass first.
    wire retrig = gate && (stage_prev == AST_REL);
    wire [25:0] level_now = retrig ? 26'd0 : level_prev;

    // kD straddles the two words: 14 bits in one, 4 in the other. Firmware
    // packs it that way because three 18-bit coefficients plus a sustain
    // level do not fit into 64 bits any other way.
    wire [17:0] k_dec = {rates2[3:0], rates[31:18]};
    wire [17:0] k_seg = !gate                   ? rates2[21:4]   // release
                      : (stage_sel == AST_ATT)  ? rates[17:0]    // attack
                      :                           k_dec;         // decay

    // Sustain is a plain level: the top 10 bits of the 22-bit envelope
    // scale. SUS_SHIFT must equal ADSR_SUS_SHIFT in app/main/patch.h. A
    // mismatch of one scales every sustain by two, and a high sustain then
    // sits above full scale and makes the decay segment climb instead of
    // settle.
    wire [25:0] sus = 26'(rates2[31:22]) << SUS_SHIFT;

    wire [25:0] target = !gate                  ? 26'd0
                       : (stage_sel == AST_ATT) ? ENV_OVER
                       :                          sus;

    // ---- stage 1: the subtract, in an ALU54D -----------------------------
    // Both operands are unsigned levels; the difference is signed and fits in
    // 27 bits, so the 54-bit result's low 36 go straight into the multiplier's
    // signed B port. The ALU registers its own output, so this IS the stage.
    //
    // EVERY parameter is given explicitly, including the ones whose default is
    // what we want. yosys omits a parameter left at its default from the JSON
    // netlist, and apicula's packer reads them with a plain dict lookup
    // (`params['C_ADD_SUB']`) rather than a default, so an omitted parameter
    // reaches gowin_pack as a bare KeyError after place-and-route has already
    // succeeded. Spelling all of them out is the difference between a build and
    // a traceback.
    wire [53:0] delta54;
    ALU54D #(
        .AREG            (1'b0),      // operands straight from the ports
        .BREG            (1'b0),
        .ASIGN_REG       (1'b0),
        .BSIGN_REG       (1'b0),
        .ACCLOAD_REG     (1'b0),
        .OUT_REG         (1'b1),      // registered: this IS the pipeline stage
        .B_ADD_SUB       (1'b1),      // DOUT = A - B
        .C_ADD_SUB       (1'b0),
        .ALUD_MODE       (0),
        .ALU_RESET_MODE  ("SYNC")
    ) u_delta (
        .A       ({28'd0, target}),
        .B       ({28'd0, level_now}),
        .ASIGN   (1'b0),
        .BSIGN   (1'b0),
        .ACCLOAD (1'b0),
        .CASI    (55'd0),
        .CLK     (clk),
        .CE      (1'b1),
        .RESET   (~rst_n),
        .DOUT    (delta54),
        .CASO    ()
    );

    // Everything the later stages need, carried alongside the DSP pipeline.
    logic [17:0] k_q;
    logic [1:0]  stage_q;
    logic [25:0] level_q;
    logic        gate_q, v1;
    logic [1:0]  stg_in_q;        // the stage we came FROM
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k_q <= '0; stage_q <= AST_IDLE; level_q <= '0;
            gate_q <= 1'b0; v1 <= 1'b0; stg_in_q <= AST_IDLE;
        end else begin
            v1       <= step_en;
            k_q      <= k_seg;
            stage_q  <= stage_sel;
            stg_in_q <= stage_prev;
            level_q  <= level_now;
            gate_q   <= gate;
        end
    end

    // delta is 27 bits; the ALU's remaining outputs are sign extension. Taking
    // only [26:0] and re-extending keeps the same value while asking the router
    // for nine fewer DSP output wires -- routing the full [35:0] failed with
    // "Found two arcs with same sink wire", which is congestion on the DSP's
    // output fabric rather than anything wrong with the arithmetic.
    wire signed [35:0] delta36 = {{9{delta54[26]}}, delta54[26:0]};

    // ---- stage 2: multiply and accumulate, in a MULTALU36X18 -------------
    // DOUT = k * delta + (level << K_SHIFT). The shift into C is wiring, and
    // the shift back out is a bit slice, so the whole recurrence costs one
    // block and no fabric arithmetic.
    wire [53:0] mac_out;
    MULTALU36X18 #(
        .AREG              (1'b0),
        .BREG              (1'b0),
        .CREG              (1'b0),
        .ASIGN_REG         (1'b0),
        .BSIGN_REG         (1'b0),
        .ACCLOAD_REG0      (1'b0),
        .ACCLOAD_REG1      (1'b0),
        .OUT_REG           (1'b1),
        .PIPE_REG          (1'b0),
        .C_ADD_SUB         (1'b0),   // add C
        .MULTALU36X18_MODE (0),      // A*B +/- C
        .MULT_RESET_MODE   ("SYNC")
    ) u_mac (
        .A       (k_q),
        .B       (delta36),
        .C       ({{(54-26-K_SHIFT){1'b0}}, level_q, {K_SHIFT{1'b0}}}),
        .ASIGN   (1'b0),             // k is unsigned
        .BSIGN   (1'b1),             // delta is signed
        .ACCLOAD (1'b0),
        .CASI    (55'd0),
        .CLK     (clk),
        .CE      (1'b1),
        .RESET   (~rst_n),
        .DOUT    (mac_out),
        .CASO    ()
    );

    // The DSP has already added the level, so this is y, not a step.
    wire [25:0] y_dsp = mac_out[K_SHIFT+25 : K_SHIFT];

    // The rest of the stage-2 context, aligned to the MAC's registered output.
    logic [1:0] stg_q;
    logic [25:0] lvl_q;
    logic        gt_q, v2;
    logic [1:0]  stg_in_d;
    logic        prod_nz_q, prod_neg_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stg_q <= AST_IDLE; lvl_q <= '0; gt_q <= 1'b0; v2 <= 1'b0;
            stg_in_d <= AST_IDLE; prod_nz_q <= 1'b0; prod_neg_q <= 1'b0;
        end else begin
            v2       <= v1;
            stg_q    <= stage_q;
            lvl_q    <= level_q;
            gt_q     <= gate_q;
            stg_in_d <= stg_in_q;
            // Whether the drive term is non-zero, and its sign, decided from
            // delta before the multiply -- k is always positive, so the
            // product's sign IS delta's sign. Keeping this out of the DSP
            // output path is what lets the creep below be a mux rather than a
            // second pass through the arithmetic.
            prod_nz_q  <= (delta54[26:0] != 27'd0) && (k_q != 18'd0);
            prod_neg_q <= delta54[26];
        end
    end

    // ---- stage 3: the creep, and the segment decision --------------------
    // Fixed-point RC STALLS: once the step truncates to zero the level freezes
    // short of its target, and on release that is a DC tail and a voice that
    // never frees -- heard as a stuck note, not as an envelope bug. One LSB of
    // creep bounds the arrival, and 1 LSB of 26 is far below anything audible.
    //
    // The DSP has already produced level + (delta*k >>> K_SHIFT), so a stall
    // shows up as y_dsp being unchanged from the level that went in. That
    // makes the creep a MUX on an incremented level rather than an extra add
    // in the arithmetic path.
    wire stalled = (y_dsp == lvl_q) && prod_nz_q;
    wire [25:0] crept = prod_neg_q ? (lvl_q - 26'd1) : (lvl_q + 26'd1);
    // A release that has already reached zero must not creep below it, and an
    // attack at the top must not creep past the comparator's reach.
    wire [25:0] y = !stalled                        ? y_dsp
                  : (prod_neg_q && lvl_q == 26'd0)  ? 26'd0
                  :                                   crept;

    logic [27:0] next;
    always_comb begin
        if (!gt_q)
            // release: target is zero, and IDLE latches on arrival
            next = (y == 26'd0) ? {AST_IDLE, 26'd0} : {AST_REL, y};
        else if (stg_q == AST_ATT)
            // attack: the comparator, not the target, ends the segment
            next = (y >= ENV_FULL) ? {AST_DEC, ENV_FULL} : {AST_ATT, y};
        else
            // decay ARRIVES at sustain. An RC segment cannot overshoot its
            // target, so the three-way compare a linear ramp needed is gone.
            next = {AST_DEC, y};
    end

    assign state_out = next;
    assign state_we  = v2;

endmodule
`default_nettype wire
