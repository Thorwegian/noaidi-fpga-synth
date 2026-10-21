#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""The chip check's board half (#235): the co-simulation's method on silicon.
`csp script <program>.s -f <seed>` (tools/csp) prints the console lines that
fill every register from the seed, load the decode ROM and the program and
start it; this sends them to the firmware's console, lets the chip run for a
moment, freezes it and reads every register back through the probe into a
file of csp-peek's lines. On the host, `csp match <program>.s -c <file> -f
<seed>` runs the model for the passes the chip's RUN_COUNT register counted
and diffs every register but the inputs: 0 differences is the acceptance.

usage: chip_check.py SCRIPT OUT [--run SECONDS] [--khz KHZ] [--port /dev/ttyACM0]

With --khz the system clock is set before the load (board_clock.py) and
restored to the design's 73.728 MHz after the read-back, whatever happened.
"""
import argparse
import re
import time

import serial

import board_clock

PORT = "/dev/ttyACM0"
REGISTERS = 0x800              # DMEM: the registers csp-peek reads, 16 a line
PEEK_WORDS = 16
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|\x1b[78]")


def command(port, line, wait):
    """One console line; what the firmware printed within `wait` seconds."""
    port.reset_input_buffer()
    port.write((line + "\r").encode())
    end = time.time() + wait
    chunks = []
    while time.time() < end:
        data = port.read(4096)
        if data:
            chunks.append(data.decode("utf-8", "replace"))
    return ANSI.sub("", "".join(chunks))


def load(port, lines):
    """Sends the script's lines; returns the ones the console refused."""
    refused = []
    for line in lines:
        # csp-hold clears the memories, which takes seconds; a row or a word is quick
        wait = 4.0 if line.startswith("csp-hold") else 0.03
        reply = command(port, line, wait)
        if "refused" in reply or "usage" in reply:
            refused.append((line, reply.strip()[:120]))
    return refused


def read_registers(port, out):
    """Every register pair through the probe, csp-peek's lines as printed."""
    with open(out, "w") as file:
        for first in range(0, REGISTERS, PEEK_WORDS):
            file.write(command(port, "csp-peek 0x%03x %d" % (first, PEEK_WORDS), 0.25))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("script", help="the lines `csp script` printed")
    parser.add_argument("out", help="where the chip's registers go, for `csp match -c`")
    parser.add_argument("--run", type=float, default=0.5, help="seconds the chip runs before the freeze")
    parser.add_argument("--khz", type=int, default=0, help="the system clock during the run, in kHz")
    parser.add_argument("--port", default=PORT)
    args = parser.parse_args()
    with open(args.script) as file:
        lines = [line.strip() for line in file if line.strip() and not line.startswith("#")]
    port = serial.Serial(args.port, 115200, timeout=0.05)
    try:
        if args.khz:
            board_clock.set_clock(args.khz)
            time.sleep(0.5)
        for line, reply in load(port, lines):
            print("the console refused:", line, reply)
        time.sleep(args.run)
        print(command(port, "csp-freeze", 0.5).strip())
        read_registers(port, args.out)
        print("sent %d lines; %s holds the registers" % (len(lines), args.out))
    finally:
        if args.khz:
            board_clock.set_clock(board_clock.DESIGN_KHZ)
        port.close()


if __name__ == "__main__":
    main()
