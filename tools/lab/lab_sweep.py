#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""The lab's clock sweep (#241, #309): each device's misses at each system
clock, in the text lab_sweep_plot.py draws.

usage: lab_sweep.py DEVICES [--mhz 73.728,85,90,...] [--window 3]
                    [--console /dev/ttyACM0] [--cli /dev/ttyUSB1]

Needs a lab bitstream (`make -C rtl pack.fs LAB_BUILD=1`, DEVICES 10, or
with LAB_BLOCKS=1, 17) loaded and the ESP32 reset after it. At each clock
the board's system clock is set through the BL616 (board_clock.py), and the
lab's counters are read twice through the firmware's `csp-raw` some seconds
apart: dword 0 counts cycles, dwords 1 … DEVICES each device's mismatches
(rtl/lab/lab.sv), and the differences are printed as

    90 MHz: <cycles> <misses of device 1> <misses of device 2> ...

The read that starts at the lab's base takes the snapshot, so one `csp-raw`
reads one instant. The clock is set back to 73.728 MHz at the end, also
after an error or Ctrl-C.
"""
import argparse
import re
import sys
import time

import serial

import board_clock

LAB_BASE = 0x0A000
DEFAULT_MHZ = "73.728,85,90,96,100,105,110,115,120,125,133"
ROW = re.compile(r"^\s*([0-9a-f]{5}):\s*[0-9a-f]+\s*\((\d+)\)")


def read_counters(console, devices):
    """One snapshot of the lab's counters: [cycles, misses of device 1, ...]."""
    console.reset_input_buffer()
    console.write(b"csp-raw 0x%05x %d\r" % (LAB_BASE, devices + 1))
    deadline, text = time.time() + 3.0, b""
    values = {}
    while time.time() < deadline and len(values) < devices + 1:
        text += console.read(4096)
        for line in text.decode("utf8", "replace").splitlines():
            match = ROW.match(re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", line))
            if match:
                values[int(match.group(1), 16) - LAB_BASE] = int(match.group(2))
    if len(values) < devices + 1:
        sys.exit("lab_sweep: csp-raw answered %d of %d dwords; is a lab bitstream loaded?" % (len(values), devices + 1))
    return [values[k] for k in range(devices + 1)]


def main():
    parser = argparse.ArgumentParser(description="the lab's misses per device at each system clock")
    parser.add_argument("devices", type=int, help="the build's lab_pkg::DEVICES (10, or 17 with LAB_BLOCKS)")
    parser.add_argument("--mhz", default=DEFAULT_MHZ, help="the clocks, comma-separated")
    parser.add_argument("--window", type=float, default=3.0, help="seconds between the two reads")
    parser.add_argument("--console", default="/dev/ttyACM0", help="the firmware's serial console")
    parser.add_argument("--cli", default=board_clock.PORT, help="the BL616's CLI port")
    args = parser.parse_args()

    console = serial.Serial(args.console, 115200, timeout=0.1)
    try:
        for mhz in (float(m) for m in args.mhz.split(",")):
            board_clock.set_clock(round(mhz * 1000), args.cli)
            time.sleep(0.5)
            first = read_counters(console, args.devices)
            time.sleep(args.window)
            second = read_counters(console, args.devices)
            print("%g MHz: %s" % (mhz, " ".join(str(b - a) for a, b in zip(first, second))), flush=True)
    finally:
        board_clock.set_clock(board_clock.DESIGN_KHZ, args.cli)
    return 0


if __name__ == "__main__":
    sys.exit(main())
