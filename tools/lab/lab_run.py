#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
# lab_run.py -- run a CSP program on the board and look at registers; checks the load.
# Needs the firmware's lab commands (csp-hold, csp-word, csp-const, csp-go).
# `csp asm` output is turned into this job by tools/lab/lab.sh.
# stdin: JSON {"words":[hex36...], "consts":[[addr,raw]...], "wait":secs, "peeks":[[addr,count]...]}
import json, re, sys, time
import serial

job = json.load(sys.stdin)
port = serial.Serial("/dev/ttyACM0", 115200, timeout=0.1)

def run(command, wait=0.25):
    port.reset_input_buffer()
    port.write(command.encode() + b"\r")
    time.sleep(wait)
    raw = port.read(16384).decode("utf8", "replace")
    raw = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "\n", raw)
    return [l.strip() for l in raw.splitlines() if l.strip()]

run("csp-hold", 1.5)
for pc, word in enumerate(job["words"]):
    run("csp-word %d %s" % (pc, word), 0.15)
for addr, raw in job["consts"]:
    run("csp-const %d %d" % (addr, raw), 0.15)
expect = 0
for pc, word in enumerate(job["words"]):
    w = int(word, 16)
    expect = (expect * 31 + pc * 7 + (w & 0xFFFFFFFF) + (w >> 32)) & 0xFFFFFFFF
for addr, raw in job["consts"]:
    expect = (expect * 31 + addr * 5 + (raw & 0x3FFFF)) & 0xFFFFFFFF
go = run("csp-go", 0.5)
loaded = [l for l in go if "loaded" in l]
if any(("checksum %08x" % expect) in l for l in loaded):
    print("loaded ok")
else:
    print("LOAD MISMATCH: expected %08x, board said %s" % (expect, loaded))
time.sleep(job.get("wait", 0.2))
for addr, count in job["peeks"]:
    for l in run("csp-peek %d %d" % (addr, count), 0.35):
        if re.match(r"^[0-9a-f]{3}:", l):
            print(l)
