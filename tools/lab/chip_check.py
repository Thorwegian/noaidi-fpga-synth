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
                     [--peek first:count ...] [--stream [--device hw:1,0]]

With --khz the system clock is set before the load (board_clock.py) and
restored to the design's 73.728 MHz after the read-back, whatever happened.
"""
import argparse
import re
import time

import serial

import board_clock
import spdif_capture

PORT = "/dev/ttyACM0"
REGISTERS = 0x800              # DMEM: the registers csp-peek reads, 16 a line
PEEK_WORDS = 16
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|\x1b[78]")
PASS_REGISTER = re.compile(r"040: [0-9a-f]{5}")


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
    """Sends the script's lines; returns the ones the console refused, and the
    pass counter's register (0x040) as the run's first pass will read it: the
    number the run before left there, peeked just before csp-go."""
    refused = []
    before = ""
    for line in lines:
        if line.startswith("csp-go"):
            match = PASS_REGISTER.search(command(port, "csp-peek 0x040 2", 0.25))
            before = match.group(0) if match else ""
        # csp-hold clears the memories, which takes seconds; a row or a word is quick
        wait = 4.0 if line.startswith("csp-hold") else 0.03
        reply = command(port, line, wait)
        if "refused" in reply or "usage" in reply:
            refused.append((line, reply.strip()[:120]))
    return refused, before


def read_registers(port, out, before, windows):
    """The registers through the probe, csp-peek's lines as printed, after a
    line with the pass counter's register before the run (csp match seeds the
    model's pass counter from the two). All of them, or the windows asked for
    (--peek), each (first, count): a micro-program's few registers in seconds."""
    with open(out, "w") as file:
        file.write("# before the run: %s\n" % before)
        for first, count in windows or [(0, REGISTERS)]:
            for at in range(first, first + count, PEEK_WORDS):
                words = min(PEEK_WORDS, first + count - at)
                file.write(command(port, "csp-peek 0x%03x %d" % (at, words), 0.25))


def window(text):
    """--peek first:count, both in any base, e.g. 0x200:32."""
    first, count = text.split(":")
    return int(first, 0), int(count, 0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("script", help="the lines `csp script` printed")
    parser.add_argument("out", help="where the chip's registers go, for `csp match -c`")
    parser.add_argument("--run", type=float, default=0.5, help="seconds the chip runs before the freeze")
    parser.add_argument("--khz", type=int, default=0, help="the system clock during the run, in kHz")
    parser.add_argument("--port", default=PORT)
    parser.add_argument("--peek", type=window, action="append",
                        help="read only this window, first:count (repeatable); default every register. "
                             "Keep 0x040:2 and RUN_COUNT's 0x3f0:16 in, for csp match")
    parser.add_argument("--stream", action="store_true",
                        help="read every register over the S/PDIF pipe (csp-stream dump, 43 ms a file) instead of peeking")
    parser.add_argument("--device", default="hw:1,0", help="--stream: the ALSA capture device of the S/PDIF input")
    args = parser.parse_args()
    with open(args.script) as file:
        lines = [line.strip() for line in file if line.strip() and not line.startswith("#")]
    port = serial.Serial(args.port, 115200, timeout=0.05)
    try:
        if args.khz:
            board_clock.set_clock(args.khz)
            time.sleep(0.5)
        refused, before = load(port, lines)
        for line, reply in refused:
            print("the console refused:", line, reply)
        time.sleep(args.run)
        print(command(port, "csp-freeze", 0.5).strip())
        if args.stream:
            # the debug port: the register file over the pipe, every register a few times over
            command(port, "csp-stream dump", 0.3)
            samples = spdif_capture.capture_stream(0.3, args.device, None)
            command(port, "csp-stream off", 0.3)
            registers = spdif_capture.analyse_stream(samples)
            spdif_capture.write_dump(registers, args.out, before)
        else:
            read_registers(port, args.out, before, args.peek)
        print("sent %d lines; %s holds the registers" % (len(lines), args.out))
    finally:
        if args.khz:
            board_clock.set_clock(board_clock.DESIGN_KHZ)
        port.close()


if __name__ == "__main__":
    main()
