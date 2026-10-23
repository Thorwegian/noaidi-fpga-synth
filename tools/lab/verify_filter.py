#!/usr/bin/env python3
"""csp-verify, read by who owns each word: real drift vs. the program's own state.

    Copyright © 2026 Thor H. Linløkken <thj@thj.no>
    License: CERN-OHL-S v2

`csp-verify` compares every register against the firmware's image, but the
program rewrites many words each pass -- envelope levels and stages, LFO phases
and outputs, channel scratch, PARITY -- so after any note they legitimately
differ from the value the firmware last seeded. Counted raw, that noise buries
the fault we are after: a FIRMWARE-OWNED word (a gate, a phase step, a depth, a
pointer) that silently did not land (#237, #244).

This runs csp-verify through tools/lab/board.py, classifies each differing
address by owner from the record layouts in tools/csp/programs/map.s, and
reports the firmware-owned differences as real drift. Exit 2 if any, else 0.

    verify_filter.py [--repo DIR] [--stdin]      (--stdin: classify saved output)
"""
import argparse
import os
import re
import subprocess
import sys

# tools/lab/verify_filter.py -> the repository root, wherever it is checked out
REPO = os.path.realpath(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", ".."))

# --- the record layouts (map.s) --------------------------------------------------
LFOS, LFO_STRIDE          = 0x080, 16
CHANNELS, CHANNEL_STRIDE  = 0x200, 64
VOICES, VOICE_STRIDE      = 0x600, 16

LFO_FIELDS = {0: "PHASE[hi]", 1: "PHASE[lo]", 2: "PHASE_STEP[hi]", 3: "PHASE_STEP[lo]",
              4: "DEPTH", 5: "NEG_DEPTH", 6: "GAIN", 7: "OUT", 8: "P", 9: "T", 10: "Z"}
LFO_PROGRAM = {0, 1, 7, 8, 9, 10}

CHANNEL_FIELDS = {28: "BEND", 29: "LFO1_PITCH", 30: "LFO1_CUTOFF", 31: "LFO2_PITCH",
                  32: "LFO2_CUTOFF", 33: "LFO1", 34: "LFO2", 35: "CUTOFF_BASE",
                  36: "KEY_TRACK", 37: "MOD_AMOUNT", 38: "CH_PITCH", 39: "CH_CUTOFF",
                  40: "TP", 41: "TC", 42: "LFO1_DUTY", 43: "LFO2_DUTY",
                  44: "LFO1_RESONANCE", 45: "LFO2_RESONANCE", 46: "DUTY_BASE_0",
                  47: "DUTY_BASE_1", 48: "RESONANCE_BASE", 49: "SINK_BLOCK",
                  50: "TD", 51: "TR"}
CHANNEL_PROGRAM = {38, 39, 40, 41, 50, 51}

VOICE_FIELDS = {0: "LEVEL_A[hi]", 1: "LEVEL_A[lo]", 2: "STAGE_A", 3: "GATE", 4: "VELOCITY",
                5: "CHANNEL", 6: "U_A", 7: "U_M", 8: "LEVEL_M[hi]", 9: "LEVEL_M[lo]",
                10: "STAGE_M", 11: "OUT_A", 12: "D", 13: "VELOCITY_M", 14: "NOTE", 15: "SINK"}
VOICE_PROGRAM = {0, 1, 2, 6, 7, 8, 9, 10, 11, 12}


def classify(address):
    """(owner, name) for a DMEM address: owner is 'program', 'firmware', 'input' or 'spare'."""
    if address < 0x040:
        return "spare", "free"
    if address < 0x060:
        return "input", "PASS" if address == 0x040 else "input"
    if address == 0x060:
        return "program", "PARITY"
    if address == 0x061:
        return "firmware", "CHANNELS_IN_USE"
    if 0x070 <= address < 0x080:
        return "firmware", f"LFO_SET{(address - 0x070) // 8}+{(address - 0x070) % 8}"
    if address < 0x080:
        return "spare", "global"
    if address < CHANNELS:
        record, offset = divmod(address - LFOS, LFO_STRIDE)
        owner = "program" if offset in LFO_PROGRAM else ("firmware" if offset in LFO_FIELDS else "spare")
        return owner, f"lfo{record}.{LFO_FIELDS.get(offset, f'SPARE+{offset}')}"
    if address < VOICES:
        record, offset = divmod(address - CHANNELS, CHANNEL_STRIDE)
        if offset < 28:
            return "firmware", f"ch{record}.ENVELOPES+{offset}"
        owner = "program" if offset in CHANNEL_PROGRAM else ("firmware" if offset in CHANNEL_FIELDS else "spare")
        return owner, f"ch{record}.{CHANNEL_FIELDS.get(offset, f'SPARE+{offset}')}"
    if address < 0x800:
        record, offset = divmod(address - VOICES, VOICE_STRIDE)
        owner = "program" if offset in VOICE_PROGRAM else "firmware"
        return owner, f"voice{record}.{VOICE_FIELDS[offset]}"
    if address < 0x900:
        return "program", f"voice_sink{(address - 0x800) // 8}+{(address - 0x800) % 8}"
    if address < 0xC00:
        return "firmware", f"channel_sink{(address - 0x900) // 48}+{(address - 0x900) % 48}"
    return "spare", "?"


LINE = re.compile(r"^\s*([0-9a-fA-F]+): image ([0-9a-f]+) \((-?\d+)\), chip ([0-9a-f]+) \((-?\d+)\)")
SUMMARY = re.compile(r"verified: (\d+) register")


def read_verify(repo):
    out = subprocess.run(["python3", f"{repo}/tools/lab/board.py", "csp-verify"],
                         capture_output=True, text=True, timeout=60).stdout
    return out


def report(text):
    real, expected = [], []
    summary = None
    for line in text.splitlines():
        m = LINE.match(line)
        if m:
            address = int(m.group(1), 16)
            owner, name = classify(address)
            entry = (address, name, int(m.group(3)), int(m.group(5)))
            (real if owner == "firmware" else expected).append((owner, entry))
            continue
        s = SUMMARY.search(line)
        if s:
            summary = int(s.group(1))
    if summary is None:
        print("verify: no summary line from the console (port busy? board.py failed?)")
        return 3
    for owner, (address, name, image, chip) in real:
        print(f"REAL DRIFT  0x{address:03x} {name:<26} image {image:>8}  chip {chip:>8}")
    for owner, (address, name, image, chip) in expected:
        print(f"expected    0x{address:03x} {name:<26} image {image:>8}  chip {chip:>8}  ({owner})")
    print(f"verify: {summary} differ -> {len(real)} real (firmware-owned), {len(expected)} expected (program state)")
    return 2 if real else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", default=REPO)
    ap.add_argument("--stdin", action="store_true", help="classify csp-verify output from stdin")
    args = ap.parse_args()
    text = sys.stdin.read() if args.stdin else read_verify(args.repo)
    sys.exit(report(text))


if __name__ == "__main__":
    main()
