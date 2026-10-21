// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_lab.sv — the lab proves itself earlier the board (#241)
//
// Every device's reference must agree with it at any clock, since in
// simulation nothing is late: thirty thousand cycles with every mismatch
// counter at zero. Then a fault is injected into each device in turn and its
// counter, and only its counter, must climb; and the snapshot the link reads must
// hold the counters as they were when the toggle came and stay put after.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_lab;
    import lab_pkg::*;

    logic clk = 0;
    always #6.781 clk = ~clk;
    logic reset_n = 1;
    logic [DEVICES-1:0] inject_fault = '0;
    logic snapshot_toggle = 0;
    logic [$clog2(synth_pkg::MAP_LAB_DWORDS)-1:0] index = '0;
    wire  [synth_pkg::SPI_DWORD_W-1:0] dword;

    lab u_lab (.clk (clk), .reset_n (reset_n), .inject_fault (inject_fault), .snapshot_toggle (snapshot_toggle),
               .index (index), .dword (dword));

    int errors = 0;

    task automatic snapshot_and_read(output logic [synth_pkg::SPI_DWORD_W-1:0] values [DEVICES + 1]);
        snapshot_toggle = ~snapshot_toggle;
        repeat (6) @(posedge clk);
        for (int d = 0; d <= DEVICES; d++) begin
            index = d; #1;
            values[d] = dword;
        end
    endtask

    logic [synth_pkg::SPI_DWORD_W-1:0] first [DEVICES + 1];
    logic [synth_pkg::SPI_DWORD_W-1:0] earlier [DEVICES + 1];
    logic [synth_pkg::SPI_DWORD_W-1:0] second [DEVICES + 1];
    logic [synth_pkg::SPI_DWORD_W-1:0] later [DEVICES + 1];
    initial begin
        reset_n = 0;
        repeat (4) @(posedge clk);
        @(negedge clk) reset_n = 1;

        $display("--- 1. every reference agrees with its device: 30000 cycles ---");
        repeat (30000) @(posedge clk);
        snapshot_and_read(first);
        for (int d = 1; d <= DEVICES; d++) begin
            if (first[d] != 0) begin $display("FAIL device %0d counted %0d mismatches with nothing late", d, first[d]); errors++; end
        end
        if (first[0] < 30000) begin $display("FAIL the cycle counter reads %0d", first[0]); errors++; end
        $display("pass: %0d cycles, every counter zero", first[0]);

        $display("--- 2. a fault injected into each device in turn is counted there, and only there ---");
        for (int f = 0; f < DEVICES; f++) begin
            snapshot_and_read(earlier);
            inject_fault = '0; inject_fault[f] = 1'b1;
            repeat (1000) @(posedge clk);
            inject_fault = '0;
            repeat (100) @(posedge clk);
            snapshot_and_read(second);
            if (second[f + 1] - earlier[f + 1] < 900 || second[f + 1] - earlier[f + 1] > 1100) begin
                $display("FAIL device %0d counted %0d of about 1000", f + 1, second[f + 1] - earlier[f + 1]); errors++;
            end
            for (int d = 1; d <= DEVICES; d++) begin
                if (d != f + 1 && second[d] != earlier[d]) begin $display("FAIL device %0d counted %0d from device %0d's fault", d, second[d] - earlier[d], f + 1); errors++; end
            end
        end
        $display("pass: every device counts its own fault and no other's");

        $display("--- 3. the snapshot stays put between toggles ---");
        repeat (5000) @(posedge clk);
        for (int d = 0; d <= DEVICES; d++) begin
            index = d; #1;
            later[d] = dword;
        end
        if (later[0] != second[0]) begin $display("FAIL the snapshot's cycle count moved without a toggle"); errors++; end
        snapshot_and_read(later);
        if (later[0] <= second[0] + 5000) begin $display("FAIL a new snapshot did not advance: %0d after %0d", later[0], second[0]); errors++; end
        $display("pass: the snapshot held, then advanced on the toggle");

        $display("");
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end
endmodule
`default_nettype wire
