// elem_prog_common.svh — shared body for the split element-program
// benches (issue #58: the monolithic tb_element_program was ~95% of
// suite wall time; four independent benches let make -j4 and CI
// matrix jobs actually parallelize). Include INSIDE a module.
//
// Provides: clocks/reset, drum + spi_bus + element_pipeline (ref
// boot fixtures), the ~20 MHz Mode-0 SPI master, the mix observer,
// flip/mute_all/program helpers, and the report task. Each bench
// owns its own initial block, preamble and timeout.

logic clk = 0, rst_n = 0;
always #6.781 clk = ~clk;               // ~73.728 MHz

logic sclk = 0, cs = 1, mosi = 0;
wire  miso;

logic       sample_tick, lane_enter;
logic [9:0] slot;
drum u_drum (
    .clk(clk), .rst_n(rst_n),
    .sample_tick(sample_tick), .lane_enter(lane_enter),
    .cell_tick(), .slot(slot)
);

wire        elem_write_enable;
wire [2:0]  elem_write_word;
wire [7:0]  elem_write_index;
wire [31:0] elem_write_data;
wire [9:0]  bus_write_addr;
wire [17:0] bus_write_data;
wire        bus_write_toggle;
wire        producer_write_enable;
wire [8:0]  producer_write_addr;
wire [31:0] producer_write_data;
wire        swap_req;

spi_bus #(.AW_BACKED(11)) u_bus (
    .sclk(sclk), .cs(cs), .mosi(mosi), .miso(miso),
    .sysclk(clk), .rst_n(rst_n),
    .elem_write_enable(elem_write_enable), .elem_write_word(elem_write_word),
    .elem_write_index(elem_write_index), .elem_write_data(elem_write_data),
    .bus_write_addr(bus_write_addr), .bus_write_data(bus_write_data), .bus_write_toggle(bus_write_toggle),
    .producer_write_enable(producer_write_enable), .producer_write_addr(producer_write_addr), .producer_write_data(producer_write_data),
    .swap_req(swap_req)
);

logic signed [23:0] ml, mr;
element_pipeline #(
    .P0_HEX("tb/ref_boot_p0.hex"), .P1_HEX("tb/ref_boot_p1.hex"),
    .P2_HEX("tb/ref_boot_p2.hex"), .P3_HEX("tb/ref_boot_p3.hex")
) u_pipe (
    .clk(clk), .rst_n(rst_n), .slot(slot),
    .lane_enter(lane_enter), .sample_tick(sample_tick),
    .sclk(sclk), .elem_write_enable(elem_write_enable), .elem_write_word(elem_write_word),
    .elem_write_index(elem_write_index), .elem_write_data(elem_write_data), .swap_req(swap_req),
    .bus_write_addr(bus_write_addr), .bus_write_data(bus_write_data), .bus_write_toggle(bus_write_toggle),
    .producer_write_enable(producer_write_enable), .producer_write_addr(producer_write_addr), .producer_write_data(producer_write_data),
    .mix_left(ml), .mix_right(mr)
);

integer errors = 0;

// ---- single source of truth (Thor, 2026-09-03) ---------------------
// Addresses come from synth_pkg (the map's one home); parameter and
// source-table words are composed from named fields here, ONCE, and
// every bench in the family uses these. No magic hex in benches.
localparam [15:0] CTRL_ADDR   = synth_pkg::MAP_CTRL_ADDR;
localparam [15:0] ELEM_BASE   = synth_pkg::MAP_ELEM_BASE;
localparam int    ELEM_STRIDE = synth_pkg::MAP_ELEM_STRIDE;
localparam [15:0] BUS_BASE    = synth_pkg::MAP_BUS_BASE;
localparam [15:0] SRC_BASE    = synth_pkg::MAP_PROD_BASE;   // code name
                                                            // pending the
                                                            // source rename

// per-element word offsets (memory_map.md +0..+6)
localparam int W_OSC = 0, W_DUTY = 1, W_FILTER = 2, W_GAIN = 3,
               W_GATE = 4, W_PTRS0 = 5, W_PTRS1 = 6;

function automatic [15:0] elem_addr(input integer e, input integer w);
    elem_addr = 16'(ELEM_BASE + 16'(e) * ELEM_STRIDE + 16'(w));
endfunction
function automatic [15:0] bus_addr(input integer b);
    bus_addr = 16'(BUS_BASE + 16'(b));
endfunction
// source table: 3 words per entry, stride 4
function automatic [15:0] src_addr(input integer entry, input integer w);
    src_addr = 16'(SRC_BASE + 16'(entry) * 4 + 16'(w));
endfunction

// the shared test timbre, in one place
localparam [13:0] FC_OPEN         = 14'h2AF8;      // ~14 kHz LP
localparam [13:0] RESO_R200       = 14'h0200;      // r: q1 = 1.0
localparam [31:0] FILTER_OPEN     = {4'b0, RESO_R200, FC_OPEN};
localparam [31:0] OSC_SINE_A4     = 32'h0000D700;  // sine, A4
localparam [31:0] OSC_SINE_C4     = 32'h0000D400;  // sine, C4
// volume semantics (issue #40): 0x00 = silence, 0xFF = loudest
localparam [31:0] GAIN_12DB_BOTH  = 32'h0000DFDF;  // -12 dB L+R
localparam [31:0] GAIN_MUTE_BOTH  = 32'h00000000;  // exact mute L+R —
                                                   // a zeroed word IS
                                                   // silence now
localparam [31:0] GAIN_CHORD_LEFT = 32'h0000009F;  // L -36 dB, R mute
localparam [31:0] GAIN_CHORD_RIGHT= 32'h00009F00;  // R -36 dB, L mute

// bus pointer words (PTRS0/PTRS1 field layouts per memory_map.md)
localparam [31:0] PTRS0_CUT_BUS1        = 32'd1 << 20;
localparam [31:0] PTRS0_CUT1_PITCH_BUS2 = (32'd1 << 20) | 32'd2;
localparam [31:0] PTRS1_GAINS_BUS3      = (32'd3 << 10) | (32'd3 << 20);

// Q8.10 bus/depth offsets — ONE name per value, used for bus bases
// and source depths alike. (The original bench comments called
// -0x2000 "-2 oct"; it is MINUS EIGHT octaves — the wrong name
// propagated into a real bug at the gain inversion, so these names
// are now checked against the value: 1 octave = 0x400.)
localparam [31:0] OFFS_PLUS_1OCT  = 32'h00000400;
localparam [31:0] OFFS_PLUS_2OCT  = 32'h00000800;
localparam [31:0] OFFS_PLUS_8OCT  = 32'h00002000;
localparam [31:0] OFFS_MINUS_8OCT = 32'h0003E000;   // 18-bit signed

// source-table words, composed from the CFG/RATES/DEPTH fields
// (memory_map.md) instead of opaque hex
localparam [31:0] SRC_OFF         = 32'h0;
localparam [31:0] SRC_LFO_TREMOLO =                 // pulse LFO,
    32'd1 | (32'd1 << 4) | (32'd3 << 6)             // gain bus 3,
          | (32'd16384 << 16);                      // 93.75 Hz
localparam [31:0] SRC_ADSR_BUS3_GATE5 =
    32'd2 | (32'd3 << 6) | (32'd5 << 16);           // ADSR type
localparam [31:0] BENCH_ADSR_RATES = 32'hF4F000F0;  // fast sim rates

// ---- Mode 0 master, ~20 MHz ---------------------------------------
localparam integer HALF = 25;
task automatic spi_word_write(input [15:0] a, input [31:0] d);
    reg [55:0] frame;   // cmd + addr(2) + word(4) = 7 bytes
    integer i;
    begin
        frame = {8'h40, a, d};
        cs = 0; #(HALF/2);
        for (i = 55; i >= 0; i = i - 1) begin
            mosi = frame[i];
            #(HALF); sclk = 1; #(HALF); sclk = 0;
        end
        #(HALF/2); cs = 1; #(2*HALF);
    end
endtask

// ---- mix observer --------------------------------------------------
longint peak, maxstep; integer nsamp;
logic signed [23:0] prev;
integer rises;
longint dstep;
task automatic observe(input integer n);
    begin
        peak = 0; nsamp = 0; rises = 0; maxstep = 0;
        prev = ml;                      // seed: no false first step
        while (nsamp < n) begin
            @(posedge clk);
            if (sample_tick) begin
                if (ml >  peak) peak =  ml;
                if (-ml > peak) peak = -ml;
                if (prev < 0 && ml >= 0) rises = rises + 1;
                dstep = ml - prev; if (dstep < 0) dstep = -dstep;
                if (dstep > maxstep) maxstep = dstep;
                prev = ml;
                nsamp = nsamp + 1;
            end
        end
    end
endtask

// request a bank flip and wait for it to take effect
task automatic flip;
    begin
        spi_word_write(CTRL_ADDR, 32'h00000001);  // CTRL: swap request
        observe(2);
    end
endtask

// reset + mute both banks (the split benches' common preamble: each
// bench builds its own state from silence)
task automatic reset_and_mute;
    integer v;
    begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        for (v = 0; v < 256; v = v + 1)
            spi_word_write(elem_addr(v, W_GAIN), GAIN_MUTE_BOTH);
        flip;
        for (v = 0; v < 256; v = v + 1)
            spi_word_write(elem_addr(v, W_GAIN), GAIN_MUTE_BOTH);
        observe(4);
    end
endtask

// program voice 0 into the CURRENT shadow: A4 SINE, open LP, -12 dB
task automatic program_v0;
    begin
        spi_word_write(elem_addr(0, W_OSC),    OSC_SINE_A4);
        spi_word_write(elem_addr(0, W_DUTY),   32'h00000000);
        spi_word_write(elem_addr(0, W_FILTER), FILTER_OPEN);
        spi_word_write(elem_addr(0, W_GAIN),   GAIN_12DB_BOTH);
    end
endtask

// firmware voice_program() mirror: C4/E4/G4/C5 on voices 0-3,
// church-organ detune, hard-panned, fc one octave above the note
function automatic [13:0] chord_pitch(input integer v);
    case (v)
        0: chord_pitch = 14'h1400;   // C4
        1: chord_pitch = 14'h1555;   // E4
        2: chord_pitch = 14'h1655;   // G4
        default: chord_pitch = 14'h1800;   // C5
    endcase
endfunction

function automatic signed [15:0] detune(input integer u);
    case (u)
        0: detune = 0;  1: detune = 2;  2: detune = 4;  3: detune = 6;
        4: detune = -2; 5: detune = -4; 6: detune = -6; default: detune = -8;
    endcase
endfunction

// (Historical note: the chord's FILTER word used to be
// 32'h40000000 | fc — a stale artifact of the OLD linear-q1
// encoding whose set bit landed in reserved space, silently running
// the chord at r = 0. Caught by the single-source-of-truth sweep,
// 2026-09-03; it now uses the shared timbre's resonance.)
task automatic program_chord;
    integer v, u;
    reg signed [15:0] pit;
    reg [13:0] fc;
    begin
        for (v = 0; v < 4; v = v + 1) begin
            fc = chord_pitch(v) + 14'h0400;
            for (u = 0; u < 8; u = u + 1) begin
                pit = $signed({2'b0, chord_pitch(v)}) + detune(u);
                spi_word_write(elem_addr(v*8+u, W_OSC),
                               {18'b0, pit[13:0]});          // saw
                spi_word_write(elem_addr(v*8+u, W_DUTY), 32'h0);
                spi_word_write(elem_addr(v*8+u, W_FILTER),
                               {4'b0, RESO_R200, fc});
                spi_word_write(elem_addr(v*8+u, W_GAIN),
                               (u < 4) ? GAIN_CHORD_LEFT
                                       : GAIN_CHORD_RIGHT);
            end
        end
    end
endtask

task automatic report;
    begin
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end
endtask

integer v, step;
longint worst, wmax, wmin;
