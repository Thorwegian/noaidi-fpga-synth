#!/usr/bin/env python3
"""csp verify, read by who owns each word: real drift vs. the program's own state.

    Copyright © 2026 Thor H. Linløkken <thj@thj.no>
    License: CERN-OHL-S v2

`csp verify` compares every register against the firmware's image, but the
program rewrites some of those words each pass (a sounding voice's envelope
levels and stages), so after any note they legitimately differ from the value
the firmware last wrote. Counted raw, that noise buries the fault we are after:
a FIRMWARE-OWNED word (a phase step, a depth, a pointer) that silently did not
land (#237, #244).

The firmware knows whose each word is, from the graph that laid the memory out,
and says so on every line and in its count. This runs csp verify through
tools/lab/board.py and reports the firmware-owned differences as real drift.
Exit 2 if any, else 0. The console lists the first 24 differing registers by
address; the count of the firmware's own covers all of them.

    verify_filter.py [--repo DIR] [--stdin]      (--stdin: classify saved output)
"""
import argparse
import os
import re
import subprocess
import sys

# tools/lab/verify_filter.py -> the repository root, wherever it is checked out
REPO = os.path.realpath(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", ".."))

LINE = re.compile(r"^\s*([0-9a-fA-F]+): image [0-9a-f]+ \((-?\d+)\), chip [0-9a-f]+ \((-?\d+)\), the (program|firmware)'s")
SUMMARY = re.compile(r"verified: (\d+) register\(s\) differ from the image, (\d+) of them the firmware's own")


def read_verify(repo):
    out = subprocess.run(["python3", f"{repo}/tools/lab/board.py", "csp verify"],
                         capture_output=True, text=True, timeout=60).stdout
    return out


def report(text):
    listed = []
    summary = None
    for line in text.splitlines():
        m = LINE.match(line)
        if m:
            listed.append((m.group(4), int(m.group(1), 16), int(m.group(2)), int(m.group(3))))
            continue
        s = SUMMARY.search(line)
        if s:
            summary = (int(s.group(1)), int(s.group(2)))
    if summary is None:
        print("verify: no summary line from the console (port busy? board.py failed?)")
        return 3
    differing, real = summary
    for owner, address, image, chip in listed:
        if owner == "firmware":
            print(f"REAL DRIFT  0x{address:03x} image {image:>8}  chip {chip:>8}")
    for owner, address, image, chip in listed:
        if owner == "program":
            print(f"expected    0x{address:03x} image {image:>8}  chip {chip:>8}  (program)")
    print(f"verify: {differing} differ -> {real} real (firmware-owned), {differing - real} expected (program state)")
    return 2 if real else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", default=REPO)
    ap.add_argument("--stdin", action="store_true", help="classify csp verify output from stdin")
    args = ap.parse_args()
    text = sys.stdin.read() if args.stdin else read_verify(args.repo)
    sys.exit(report(text))


if __name__ == "__main__":
    main()
