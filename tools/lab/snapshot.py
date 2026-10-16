#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
# snapshot.py -- the CSP's registers before and after a few passes.
#
#   snapshot.py before.txt after.txt [milliseconds]
#
# Freezes the CSP (csp-freeze: its program stays, the engine's tick stops),
# dumps every register (csp-dump), lets the CSP run for a few milliseconds
# (csp-step), freezes it again and dumps again. `csp replay` runs the model
# from the first snapshot and compares it with the second.
import re
import sys
import time

import serial

PORT = "/dev/ttyACM0"


def command(port, text, until, timeout):
    port.reset_input_buffer()
    port.write(text.encode() + b"\r")
    started, raw = time.time(), b""
    while time.time() - started < timeout:
        raw += port.read(4096)
        if until.encode() in raw:
            break
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "\n", raw.decode("utf8", "replace"))


def dump(port, path):
    text = command(port, "csp-dump", "dumped", 40)
    lines = {}
    for match in re.finditer(r"R ([0-9a-f]{3}) ([0-9a-f]{5}) ([0-9a-f]{5})", text):
        lines[int(match.group(1), 16)] = match.group(0)
    with open(path, "w") as out:
        for address in sorted(lines):
            out.write(lines[address] + "\n")
    print("%s: %d register pairs" % (path, len(lines)))


port = serial.Serial(PORT, 115200, timeout=0.2)
before, after = sys.argv[1], sys.argv[2]
milliseconds = sys.argv[3] if len(sys.argv) > 3 else "2"
command(port, "csp-freeze", "frozen", 5)
dump(port, before)
command(port, "csp-step " + milliseconds, "stepped", 5)
dump(port, after)
