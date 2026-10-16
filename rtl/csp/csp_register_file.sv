//------------------------------------------------------------------------
// csp_register_file.sv — the CSP's 2048 registers, three reads a cycle
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// 2048 × 18-bit registers with three read ports (the A, X and Y
// operands) and one write port, as docs/csp_isa.md section 5 describes.
// A wide register is an aligned pair (upper word even) read or written
// as one 36-bit value in a single cycle.
//
// Each read port has its own copy of the registers, because every copy
// must also take every write: a BSRAM's two ports are one write and one
// read here, so three reads a cycle need three copies. A copy is two
// banks of 1024 × 18, even and odd registers, so that an 18-bit write
// touches one bank and a wide access touches both at the same index:
// one BSRAM per bank, six in all.
//
// A write is taken into a register of each copy's own (the bank enables,
// the index and the words, decoded before it) and lands in the banks the
// clock after: the banks' write pins see nothing but a register next to
// them. Driven straight from the core, the write's address bits fanned out
// over the chip to six blocks the tool does not time at their pins, and on
// the board at 73.728 MHz a run of stores on consecutive cycles landed with
// address bits dropped (docs/csp_isa.md section 12). The pass counter's
// write, one isolated word a pass, goes in directly, so that it lands
// before the pass's first instruction reads it.
//
// Reads are synchronous: the address goes in on one clock, the words
// come out on the next, straight from the banks' output registers: the
// even and the odd word of the pair, which the core takes into a register
// of its own before choosing a half or taking the pair (nothing but a
// register on a block RAM's output, docs/csp_isa.md section 12: the tool
// does not time what follows one). A read of the register being written
// in the same cycle returns the old value; the core's hazard check covers
// that case. Register 0 is never written, so it always reads zero, and a
// wide write to the pair at 0 is discarded.
//------------------------------------------------------------------------
`default_nettype none
module csp_register_file (
    input  wire clk,
    input  wire reset_n,      // clears the copies' write registers only; the banks keep their contents

    // three read ports: A, X, Y
    input  wire [2:0][csp_pkg::REGISTER_W-1:0] read_address,
    output logic [2:0][csp_pkg::WORD_W-1:0]    read_even,    // the pair's upper word
    output logic [2:0][csp_pkg::WORD_W-1:0]    read_odd,     // and its lower

    // one write port: taken into each copy's register now, in the banks
    // the clock after
    input  wire                                write_enable,
    input  wire [csp_pkg::REGISTER_W-1:0]      write_address,
    input  wire                                write_wide,
    input  wire [csp_pkg::WIDE_W-1:0]          write_data,   // word: low 18 bits
    // the pass counter: in the banks this clock, at IO_BASE
    input  wire                                counter_write,
    input  wire [csp_pkg::WORD_W-1:0]          counter_data
);
    localparam int BANK_DEPTH = csp_pkg::REGISTER_COUNT / 2;
    localparam int BANK_W     = csp_pkg::REGISTER_W - 1;

    // A write: which banks, at which index, with what.
    wire [BANK_W-1:0] write_index = write_address[csp_pkg::REGISTER_W-1:1];
    wire              write_odd   = write_address[0];
    wire              discard     = write_address == '0;  // ZERO, or the pair at 0
    wire              write_even_bank = write_enable && !discard && (write_wide || !write_odd);
    wire              write_odd_bank  = write_enable && !discard && (write_wide ||  write_odd);
    wire [csp_pkg::WORD_W-1:0] even_data = write_wide ? write_data[csp_pkg::WIDE_W-1:csp_pkg::WORD_W] : write_data[csp_pkg::WORD_W-1:0];
    wire [csp_pkg::WORD_W-1:0] odd_data  = write_data[csp_pkg::WORD_W-1:0];
    localparam logic [BANK_W-1:0] COUNTER_INDEX = BANK_W'(csp_pkg::IO_BASE >> 1);   // an even register

    for (genvar port = 0; port < 3; port++) begin : g_copy
        logic [csp_pkg::WORD_W-1:0] even_bank [BANK_DEPTH];
        logic [csp_pkg::WORD_W-1:0] odd_bank  [BANK_DEPTH];
        initial begin
            for (int index = 0; index < BANK_DEPTH; index++) begin
                even_bank[index] = '0;
                odd_bank[index]  = '0;
            end
        end

        // This copy's write register: the decoded write, a clock before the
        // banks take it.
        logic                       even_write_q, odd_write_q;
        logic [BANK_W-1:0]          index_q;
        logic [csp_pkg::WORD_W-1:0] even_data_q, odd_data_q;
        always_ff @(posedge clk or negedge reset_n) begin
            if (!reset_n) begin
                even_write_q <= 1'b0;
                odd_write_q  <= 1'b0;
            end else begin
                even_write_q <= write_even_bank;
                odd_write_q  <= write_odd_bank;
            end
        end
        always_ff @(posedge clk) begin
            index_q      <= write_index;
            even_data_q  <= even_data;
            odd_data_q   <= odd_data;
        end

        // Sync-only processes, so yosys infers a BSRAM per bank.
        always_ff @(posedge clk) begin
            if (even_write_q || counter_write) begin
                even_bank[counter_write ? COUNTER_INDEX : index_q] <= counter_write ? counter_data : even_data_q;
            end
        end
        always_ff @(posedge clk) begin
            if (odd_write_q) begin
                odd_bank[index_q] <= odd_data_q;
            end
        end

        wire [BANK_W-1:0] read_index = read_address[port][csp_pkg::REGISTER_W-1:1];
        always_ff @(posedge clk) begin
            read_even[port] <= even_bank[read_index];
            read_odd[port]  <= odd_bank[read_index];
        end
    end

endmodule
`default_nettype wire
