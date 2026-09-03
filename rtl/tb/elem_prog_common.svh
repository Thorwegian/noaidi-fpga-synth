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
        spi_word_write(16'h0002, 32'h00000001);   // CTRL: swap request
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
            spi_word_write(16'h2000 + 16'(v)*64 + 16'd3, 32'h0000FFFF);
        flip;
        for (v = 0; v < 256; v = v + 1)
            spi_word_write(16'h2000 + 16'(v)*64 + 16'd3, 32'h0000FFFF);
        observe(4);
    end
endtask

// program voice 0 into the CURRENT shadow: A4 SINE, open LP, -12 dB
task automatic program_v0;
    begin
        spi_word_write(16'h2000, 32'h0000D700);   // OSC: A4, sine
        spi_word_write(16'h2001, 32'h00000000);   // DUTY
        spi_word_write(16'h2002, 32'h00802AF8);   // FILTER: r=0x200, open
        spi_word_write(16'h2003, 32'h00002020);   // GAIN L/R -12 dB
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

task automatic program_chord;
    integer v, u;
    reg signed [15:0] pit;
    reg [13:0] fc;
    begin
        for (v = 0; v < 4; v = v + 1) begin
            fc = chord_pitch(v) + 14'h0400;
            for (u = 0; u < 8; u = u + 1) begin
                pit = $signed({2'b0, chord_pitch(v)}) + detune(u);
                spi_word_write(16'h2000 + 16'(v*8+u)*64 + 16'd0,
                               {18'b0, pit[13:0]});          // saw
                spi_word_write(16'h2000 + 16'(v*8+u)*64 + 16'd1, 32'h0);
                spi_word_write(16'h2000 + 16'(v*8+u)*64 + 16'd2,
                               32'h40000000 | 32'(fc));
                spi_word_write(16'h2000 + 16'(v*8+u)*64 + 16'd3,
                               (u < 4) ? 32'h0000FF60 : 32'h000060FF);
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
