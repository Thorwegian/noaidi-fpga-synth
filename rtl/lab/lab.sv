//------------------------------------------------------------------------
// lab.sv — the lab: devices under test, their counters, the snapshot the link reads (#241)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Where each logic element breaks on this chip, measured: every device
// under test (rtl/lab/dut_*.sv) computes something through the element in
// one cycle and a reference computes the same thing the slow, known-good
// way; a cycle in which they differ is a mismatch, and each device has a
// saturating counter of them. The firmware reads the counters at a raised
// clock, twice some seconds apart, and the difference is the device's miss
// rate at that clock. Dword 0 is a free-running cycle counter the rates are
// measured against; dwords 1 … DEVICES are the devices in the order below.
//
// The counters run on the system clock and the link reads on the SPI
// clock: when a read frame starts at the lab's base, the bus toggles
// lab_snapshot, the lab copies every counter into a snapshot bank within a
// few cycles (the frame's turnaround is dozens), and the link reads the
// bank, which does not change until the next frame at the base. A
// multi-bit value crossing clocks is only ever read while it is still.
//
// The stimulus is two LFSRs side by side (a 64-bit, x^64 + x^63 + x^61 +
// x^60 + 1, and the stream's 32-bit), stepped every cycle, so every device
// sees a new pattern every cycle. inject_fault is the bench's: it corrupts
// one device's result so the counting itself is proved.
//------------------------------------------------------------------------
`default_nettype none
module lab (
    input  wire                                   clk,
    input  wire                                   reset_n,
    input  wire [lab_pkg::DEVICES-1:0]            inject_fault,     // simulation only: a device's result corrupted
    input  wire                                   snapshot_toggle,  // from the bus, on the SPI clock
    input  wire [$clog2(synth_pkg::MAP_LAB_DWORDS)-1:0] index,      // which dword the link reads
    output logic [synth_pkg::SPI_DWORD_W-1:0]     dword
);

    // ---- the stimulus ----
    logic [63:0] lfsr64;
    logic [31:0] lfsr32;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            lfsr64 <= 64'h1;
            lfsr32 <= 32'h1;
        end else begin
            lfsr64 <= {lfsr64[62:0], lfsr64[63] ^ lfsr64[62] ^ lfsr64[60] ^ lfsr64[59]};
            lfsr32 <= lfsr32[0] ? ((lfsr32 >> 1) ^ 32'h00400007) : (lfsr32 >> 1);   // the stream's Galois taps
        end
    end
    wire [lab_pkg::STIMULUS_W-1:0] stimulus = {lfsr64, lfsr32};

    // ---- the devices ----
    logic [lab_pkg::DEVICES-1:0] mismatch;

    dut_lut_chain   #(.LEVELS (2))  u_lut_2     (.clk (clk), .reset_n (reset_n), .stimulus (stimulus), .inject_fault (inject_fault[0]), .mismatch (mismatch[0]));
    dut_lut_chain   #(.LEVELS (4))  u_lut_4     (.clk (clk), .reset_n (reset_n), .stimulus (stimulus), .inject_fault (inject_fault[1]), .mismatch (mismatch[1]));
    dut_lut_chain   #(.LEVELS (6))  u_lut_6     (.clk (clk), .reset_n (reset_n), .stimulus (stimulus), .inject_fault (inject_fault[2]), .mismatch (mismatch[2]));
    dut_lut_chain   #(.LEVELS (8))  u_lut_8     (.clk (clk), .reset_n (reset_n), .stimulus (stimulus), .inject_fault (inject_fault[3]), .mismatch (mismatch[3]));
    dut_lut_chain   #(.LEVELS (10)) u_lut_10    (.clk (clk), .reset_n (reset_n), .stimulus (stimulus), .inject_fault (inject_fault[4]), .mismatch (mismatch[4]));
    dut_carry_chain #(.BITS (18))   u_carry_18  (.clk (clk), .reset_n (reset_n), .stimulus (stimulus), .inject_fault (inject_fault[5]), .mismatch (mismatch[5]));
    dut_carry_chain #(.BITS (36))   u_carry_36  (.clk (clk), .reset_n (reset_n), .stimulus (stimulus), .inject_fault (inject_fault[6]), .mismatch (mismatch[6]));
    dut_carry_chain #(.BITS (54))   u_carry_54  (.clk (clk), .reset_n (reset_n), .stimulus (stimulus), .inject_fault (inject_fault[7]), .mismatch (mismatch[7]));
    // the blocks and the nets the chains do not have: the DSP's multiply-add, a block RAM's data out
    // into logic, an adder in front of a block RAM's address pins, a register's fan-out — a build
    // of their own (lab_pkg.sv: LAB_BLOCKS), since their references do not fit beside the CSP
    if (lab_pkg::DEVICES > 8) begin : g_blocks
    dut_dsp         #(.PIPE (0))            u_dsp          (.clk (clk), .reset_n (reset_n), .stimulus (stimulus), .inject_fault (inject_fault[8]),  .mismatch (mismatch[8]));
    dut_dsp         #(.PIPE (1))            u_dsp_piped    (.clk (clk), .reset_n (reset_n), .stimulus (stimulus), .inject_fault (inject_fault[9]),  .mismatch (mismatch[9]));
    dut_bsram       #(.LOGIC_AFTER (1'b1))  u_bsram_logic  (.clk (clk), .reset_n (reset_n), .stimulus (stimulus), .inject_fault (inject_fault[10]), .mismatch (mismatch[10]));
    dut_bsram       #(.LOGIC_AFTER (1'b0))  u_bsram_reg    (.clk (clk), .reset_n (reset_n), .stimulus (stimulus), .inject_fault (inject_fault[11]), .mismatch (mismatch[11]));
    dut_bsram_pins  #(.ADDER (1'b1))        u_pins_adder   (.clk (clk), .reset_n (reset_n), .stimulus (stimulus), .inject_fault (inject_fault[12]), .mismatch (mismatch[12]));
    dut_bsram_pins  #(.ADDER (1'b0))        u_pins_reg     (.clk (clk), .reset_n (reset_n), .stimulus (stimulus), .inject_fault (inject_fault[13]), .mismatch (mismatch[13]));
    dut_fanout      #(.FANOUT (64))         u_fanout_64    (.clk (clk), .reset_n (reset_n), .stimulus (stimulus), .inject_fault (inject_fault[14]), .mismatch (mismatch[14]));
    end

    // ---- the counters: cycles, and each device's mismatches, saturating ----
    logic [lab_pkg::COUNTER_W-1:0] cycles;
    logic [lab_pkg::COUNTER_W-1:0] counter [lab_pkg::DEVICES];
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cycles <= '0;
            for (int d = 0; d < lab_pkg::DEVICES; d++) counter[d] <= '0;
        end else begin
            cycles <= cycles + 1'b1;
            for (int d = 0; d < lab_pkg::DEVICES; d++) begin
                if (mismatch[d] && counter[d] != '1) counter[d] <= counter[d] + 1'b1;
            end
        end
    end

    // ---- the snapshot the link reads ----
    logic snapshot_meta, snapshot_sync, snapshot_seen;
    logic [lab_pkg::COUNTER_W-1:0] snapshot [lab_pkg::DEVICES + 1];
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            {snapshot_meta, snapshot_sync, snapshot_seen} <= '0;
            for (int d = 0; d <= lab_pkg::DEVICES; d++) snapshot[d] <= '0;
        end else begin
            {snapshot_meta, snapshot_sync} <= {snapshot_toggle, snapshot_meta};
            snapshot_seen <= snapshot_sync;
            if (snapshot_sync != snapshot_seen) begin
                snapshot[0] <= cycles;
                for (int d = 0; d < lab_pkg::DEVICES; d++) snapshot[d + 1] <= counter[d];
            end
        end
    end

    always_comb begin
        dword = '0;
        for (int d = 0; d <= lab_pkg::DEVICES; d++) begin
            if (int'(index) == d) dword = synth_pkg::SPI_DWORD_W'(snapshot[d]);
        end
    end

endmodule
`default_nettype wire
