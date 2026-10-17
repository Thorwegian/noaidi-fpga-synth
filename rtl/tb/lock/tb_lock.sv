// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_lock.sv -- csp_core and its synthesized netlist, side by side
//
// The same inputs go to csp_core (the RTL) and to csp_core_gate (what yosys
// made of it, with Gowin's cell models); every clock their outputs are
// compared. Both run the boot self-test program (tools/csp/programs/
// selftest.s) through its LFO configuration, for 400 passes. A difference is
// a place where the synthesis does not mean what the RTL says, and the board
// follows the synthesis: the hazard check once synthesized to logic that never
// stalled (csp_core.sv, stage_hazard), which no RTL simulation could show.
// `make sim-lockstep` in rtl/.
//------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_lock;
    logic clk = 0, sclk = 0, reset_n = 0;
    always #6.78 clk = ~clk;
    logic held = 1;

    // SPI-side drivers
    logic imem_we = 0; logic [csp_pkg::PROGRAM_W-1:0] imem_a = 0; logic [35:0] imem_d = 0;
    logic q_we = 0; logic [csp_pkg::QUEUE_ADDRESS_W-1:0] q_a = 0; logic [csp_pkg::WORD_W-1:0] q_d = 0; logic q_swap = 0;
    task automatic imem_write(input int a, input logic [35:0] d);
        imem_a = a; imem_d = d; imem_we = 1; #50 sclk = 1; #50 sclk = 0; imem_we = 0;
    endtask
    task automatic queue_put(input int a, input int d);
        q_a = a; q_d = d; q_we = 1; #50 sclk = 1; #50 sclk = 0; q_we = 0;
    endtask
    task automatic queue_swap;
        q_swap = 1; #50 sclk = 1; #50 sclk = 0; q_swap = 0;
    endtask
    `include "selftest.svh"

    logic [csp_pkg::PROGRAM_W-1:0] fetch_address, fetch_address_g;
    logic [35:0] fetch_data, fetch_data_g;
    wire queue_pop, queue_pop_g, queue_committed, queue_full;
    wire [csp_pkg::QUEUE_ADDRESS_W-1:0] queue_address;
    wire [csp_pkg::WORD_W-1:0] queue_data;
    logic pass_start = 0;

    csp_instruction_memory imem (.sclk(sclk), .held(held), .write_enable(imem_we), .write_address(imem_a), .write_data(imem_d),
                                 .clk(clk), .fetch_address(fetch_address), .fetch_data(fetch_data));
    csp_instruction_memory imem_g (.sclk(sclk), .held(held), .write_enable(imem_we), .write_address(imem_a), .write_data(imem_d),
                                 .clk(clk), .fetch_address(fetch_address_g), .fetch_data(fetch_data_g));
    csp_write_queue queue (.sclk(sclk), .sclk_reset_n(reset_n), .write_enable(q_we), .write_address(q_a), .write_data(q_d), .swap(q_swap), .full(queue_full),
                           .clk(clk), .reset_n(reset_n), .pop(queue_pop), .committed(queue_committed), .head_address(queue_address), .head_data(queue_data), .read_pointer_gray());

    logic sw, sw_g, sb, sb_g, pd, pd_g;
    logic [9:0] sa, sa_g; logic [17:0] sd, sd_g; logic [17:0] pc, pc_g; logic [35:0] pr, pr_g;
    logic [10:0] probe_address = 11'h062;

    csp_core rtl (.clk(clk), .reset_n(reset_n), .pass_start(pass_start), .held(held), .fetch_address(fetch_address), .fetch_data(fetch_data),
        .queue_pop(queue_pop), .queue_committed(queue_committed), .queue_address(queue_address), .queue_data(queue_data),
        .sink_write_enable(sw), .sink_write_both(sb), .sink_write_address(sa), .sink_write_data(sd), .pass_done(pd), .pass_counter(pc),
        .probe_address(probe_address), .probe_data(pr));
    csp_core_gate gate (.clk(clk), .reset_n(reset_n), .pass_start(pass_start), .held(held), .fetch_address(fetch_address_g), .fetch_data(fetch_data_g),
        .queue_pop(queue_pop_g), .queue_committed(queue_committed), .queue_address(queue_address), .queue_data(queue_data),
        .sink_write_enable(sw_g), .sink_write_both(sb_g), .sink_write_address(sa_g), .sink_write_data(sd_g), .pass_done(pd_g), .pass_counter(pc_g),
        .probe_address(probe_address), .probe_data(pr_g));

    integer cycle = 0, bad = 0;
    logic [1535:0] dummy;
    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (reset_n) begin
            if ({fetch_address, queue_pop, sw, sb, sa, sd, pd, pc, pr} !== {fetch_address_g, queue_pop_g, sw_g, sb_g, sa_g, sd_g, pd_g, pc_g, pr_g}) begin
                bad = bad + 1;
                if (bad <= 6)
                    $display("MISMATCH cycle %0d: fetch %0d/%0d pop %b/%b sink_we %b/%b addr %0d/%0d data %0d/%0d probe %h/%h",
                        cycle, fetch_address, fetch_address_g, queue_pop, queue_pop_g, sw, sw_g, sa, sa_g, $signed(sd), $signed(sd_g), pr, pr_g);
            end
        end
    end

    // GSR for the vendor primitives
    GSR GSR (.GSRI(1'b1));

    integer pass_count_run = 0;
    initial begin
        #100 reset_n = 0; #200 reset_n = 1;
        load_selftest();
        // run passes: pass_start every 1536 cycles
        repeat (400) begin
            repeat (3) @(posedge clk);
            if (pass_count_run == 4) held = 0;
            repeat (1) begin pass_start = 1; @(posedge clk); pass_start = 0; end
            repeat (1532) @(posedge clk);
            pass_count_run = pass_count_run + 1;
        end
        $display("done: %0d mismatching cycles, final probe rtl %h gate %h", bad, pr, pr_g);
        $finish;
    end
endmodule
