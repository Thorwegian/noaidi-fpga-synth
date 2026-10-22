#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
# board.py -- send console commands to the ESP32 and print what comes back.
#
#   board.py [--reset SECONDS] ["command" ...]
#
# --reset restarts the ESP32 (RTS) first and prints its boot log for SECONDS.
# The commands are those of the firmware's console (app/main/cli*.cpp), for
# instance "csp-diag" or "csp-peek 0x40 2". Port: /dev/ttyACM0.
import re
import sys
import time

import serial

PORT = "/dev/ttyACM0"


def clean(raw):
    text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "\n", raw.decode("utf8", "replace"))
    text = re.sub(r"\x1b[78]", "", text)
    return [line.rstrip() for line in text.splitlines() if line.strip()]


def main():
    port = serial.Serial(PORT, 115200, timeout=0.2)
    args = sys.argv[1:]
    if args and args[0] == "--reset":
        seconds = float(args[1]) if len(args) > 1 else 6.0
        args = args[2:]
        port.dtr = False
        port.rts = True
        time.sleep(0.2)
        port.rts = False
        started, raw = time.time(), b""
        while time.time() - started < seconds:
            raw += port.read(4096)
        for line in clean(raw):
            print("| " + line[:170])
    for command in args:
        port.reset_input_buffer()
        port.write(command.encode() + b"\r")
        time.sleep(0.3)
        started, raw = time.time(), b""
        while time.time() - started < 2.0:
            raw += port.read(4096)
        print(">>", command)
        for line in clean(raw):
            if line.strip() != command:
                print("   " + line[:170])


main()
