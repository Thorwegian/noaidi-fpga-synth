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
// Every register on the banks' pins is the bank's own, placed beside its
// block (csp_bank.sv): the tool does not time a path into or out of a
// block RAM's pin, and a register it placed with the logic that feeds it,
// tens of tiles away, is a path of the order of the clock period at
// 73.728 MHz (docs/csp_isa.md section 12, docs/gowin_oss_notes.md).
//
//   - A write is taken into each bank's register (the bank enables, the
//     index and the words, decoded before it) and lands in the block the
//     clock after. The pass counter's write comes the same way, on a
//     pass's last cycle, and lands before the next pass's first
//     instruction reads it.
//   - A read's address goes into the bank's register (read_address: what
//     the core's address stage takes this clock; held while read_hold, so
//     that an instruction waiting in A keeps its operands on the pins),
//     the block reads it the clock after, and its output register holds
//     the even and the odd word of the pair the clock after that. While
//     read_park (no instruction reads: the drain, the write window, a
//     held pass) every port's register holds csp_pkg::PARK_REGISTER's
//     row, which nothing writes: a block reads the row on its pins on
//     every clock, and on the board a row read while the other port
//     wrote it lost the write (csp_bank.sv).
//   - The pair is taken into the bank's output register, and that is what
//     read_even / read_odd are: the core's E1 operands, three clocks
//     after the address was given, with the core choosing a half or
//     taking the pair from them.
//
// A read of the register being written in the same cycle returns the old
// value; the core's hazard check covers that case. Register 0 is never
// written, so it always reads zero, and a wide write to the pair at 0 is
// discarded. The sites are the middle row of the chip's block RAMs, by
// the core's logic, and the banks' flip-flops the fabric rows beside it.
//------------------------------------------------------------------------
`default_nettype none
module csp_register_file #(
    // the banks' BSRAM sites, even and odd of each copy (csp_bank.sv: the
    // columns on the middle row, whose three columns and the rows beside
    // it hold the bank's flip-flops; negative leaves a bank to the placer)
    parameter int SITE_Y      = 27,
    parameter int SITE_EVEN_0 = 13,
    parameter int SITE_ODD_0  = 16,
    parameter int SITE_EVEN_1 = 19,
    parameter int SITE_ODD_1  = 22,
    parameter int SITE_EVEN_2 = 31,           // the middle row has no sites at X25 and X28
    parameter int SITE_ODD_2  = 34
) (
    input  wire clk,
    input  wire reset_n,      // unused: the banks' registers start clear and keep their contents

    // three read ports: A, X, Y. The address as the core's address stage
    // takes it; the pair three clocks later
    input  wire [2:0][csp_pkg::REGISTER_W-1:0] read_address,
    input  wire                                read_hold,    // the address stage waits: addresses held
    input  wire [2:0]                          read_park,    // per port: no instruction reads, the port on PARK_REGISTER's row
    output logic [2:0][csp_pkg::WORD_W-1:0]    read_even,    // the pair's upper word
    output logic [2:0][csp_pkg::WORD_W-1:0]    read_odd,     // and its lower

    // one write port: taken into each bank's register now, in the blocks
    // the clock after
    input  wire                                write_enable,
    input  wire [csp_pkg::REGISTER_W-1:0]      write_address,
    input  wire                                write_wide,
    input  wire [csp_pkg::WIDE_W-1:0]          write_data    // word: low 18 bits
);
    localparam int BANK_W     = csp_pkg::REGISTER_W - 1;

    // A write: which banks, at which index, with what.
    wire [BANK_W-1:0] write_index = write_address[csp_pkg::REGISTER_W-1:1];
    localparam logic [BANK_W-1:0] PARK_INDEX = BANK_W'(csp_pkg::PARK_REGISTER >> 1);   // the parked pair's row
    wire              write_odd   = write_address[0];
    wire              discard     = write_address == '0;  // ZERO, or the pair at 0
    wire              write_even_bank = write_enable && !discard && (write_wide || !write_odd);
    wire              write_odd_bank  = write_enable && !discard && (write_wide ||  write_odd);
    wire [csp_pkg::WORD_W-1:0] even_data = write_wide ? write_data[csp_pkg::WIDE_W-1:csp_pkg::WORD_W] : write_data[csp_pkg::WORD_W-1:0];
    wire [csp_pkg::WORD_W-1:0] odd_data  = write_data[csp_pkg::WORD_W-1:0];

    for (genvar port = 0; port < 3; port++) begin : g_copy
        localparam int SITE_EVEN = port == 0 ? SITE_EVEN_0 : port == 1 ? SITE_EVEN_1 : SITE_EVEN_2;
        localparam int SITE_ODD  = port == 0 ? SITE_ODD_0  : port == 1 ? SITE_ODD_1  : SITE_ODD_2;

        wire [BANK_W-1:0] read_index = read_address[port][csp_pkg::REGISTER_W-1:1];
        csp_bank #(
            .SITE_X(SITE_EVEN), .SITE_Y(SITE_Y), .ADDRESS_REGISTER(1'b1), .OUTPUT_REGISTER(1'b1),
            .PARK_INDEX(PARK_INDEX)
        ) u_even (
            .clk          (clk),
            .write_enable (write_even_bank),
            .write_index  (write_index),
            .write_data   (even_data),
            .read_index   (read_index),
            .read_hold    (read_hold),
            .read_park    (read_park[port]),
            .read_data    (read_even[port])
        );
        csp_bank #(
            .SITE_X(SITE_ODD), .SITE_Y(SITE_Y), .ADDRESS_REGISTER(1'b1), .OUTPUT_REGISTER(1'b1),
            .PARK_INDEX(PARK_INDEX)
        ) u_odd (
            .clk          (clk),
            .write_enable (write_odd_bank),
            .write_index  (write_index),
            .write_data   (odd_data),
            .read_index   (read_index),
            .read_hold    (read_hold),
            .read_park    (read_park[port]),
            .read_data    (read_odd[port])
        );
    end

endmodule
`default_nettype wire
