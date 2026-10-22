#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""The board's system clock, set without a rebuild: the Tang Nano 20K's BL616
has a CLI on the board's second serial port (/dev/ttyUSB1) whose
`pll_clk O0=<kHz>K` reprograms the clock generator the FPGA runs on, at once.
The design's clock is 73.728 MHz, and every measurement at another clock ends
by restoring it (docs/gowin_oss_notes.md section 3): `chip_check.py --khz`
and the lab sweep do so themselves.

usage: board_clock.py KHZ [--port /dev/ttyUSB1]
       board_clock.py --command "<BL616 CLI line>" [--port /dev/ttyUSB1]

Prints the CLI's reply (the `O0:` line carries the clock it set). From
Python, `set_clock(khz)` does the same.
"""
import argparse
import re
import time

import serial

PORT = "/dev/ttyUSB1"
DESIGN_KHZ = 73728
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def open_cli(port=PORT):
    """The BL616's CLI, with its line editor cleared (Ctrl-X, Ctrl-C, CR)."""
    cli = serial.Serial(port, 115200, timeout=0.3, dsrdtr=False, rtscts=False)
    cli.dtr = True
    cli.rts = True
    time.sleep(0.3)
    for key in (b"\x18", b"\x03", b"\r"):
        cli.write(key)
        time.sleep(0.15)
    time.sleep(0.5)
    cli.read(1000)
    return cli


def command(cli, line, wait=1.0):
    """One CLI line, a character at a time (the CLI drops bytes sent at once)."""
    cli.reset_input_buffer()
    for byte in line.encode() + b"\r":
        cli.write(bytes([byte]))
        time.sleep(0.01)
    time.sleep(wait)
    return ANSI.sub("", cli.read(4000).decode("utf-8", "replace")).strip()


def set_clock(khz, port=PORT):
    """Sets the system clock to `khz` and returns the CLI's reply."""
    cli = open_cli(port)
    try:
        return command(cli, "pll_clk O0=%dK" % khz)
    finally:
        cli.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("khz", nargs="?", type=int, help="the system clock to set, in kHz")
    parser.add_argument("--command", help="any BL616 CLI line instead")
    parser.add_argument("--port", default=PORT)
    args = parser.parse_args()
    if args.command:
        cli = open_cli(args.port)
        try:
            print(command(cli, args.command))
        finally:
            cli.close()
    elif args.khz:
        print(set_clock(args.khz, args.port))
    else:
        parser.error("a clock in kHz or --command")


if __name__ == "__main__":
    main()
