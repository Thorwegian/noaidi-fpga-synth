#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""The control program's chip check (#236): the program the firmware runs,
on the chip against the model, from a fill — with the registers that point
set to what the program's layout expects, so that every indexed read and
write stays where the model can follow it (the fill alone would send the
channels' sink words and the LFO records anywhere).

The pointers come from the program's own layout (app/main/csp/control_program.hpp,
which `csp header` generates): the LFO sets' bases, each channel's LFO
records, its own sink block and its bend, each voice's channel and sinks —
as the firmware's image wires them (render.cpp), so that nothing the check
leaves in the chip can alias what the firmware uses; the firmware's boot
zeroes every register anyway. The program is assembled with
checks/control_counts.s (one sine fewer than the firmware's layout, which
sits at the pass's cycle limit) and checks/run_count.s (the pass count csp
match needs).

usage: control_check.py writes            the `-w address=raw` flags
       control_check.py script [-f SEED]  the console lines, as `csp script` prints them
       control_check.py match DUMP [-f SEED]  the model against the chip's dump

The board side is tools/lab/chip_check.py on the script's output; peek
windows worth having: 0x040:2 0x060:32 0x080:64 0x200:64 0x600:32 0x3f0:16.
"""
import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEADER = os.path.join(ROOT, "app", "main", "csp", "control_program.hpp")
CSP = os.path.join(ROOT, "app", "build", "host", "csp")
PROGRAMS = os.path.join(ROOT, "tools", "csp", "programs")
SOURCES = ["map.s", "checks/control_counts.s", "checks/run_count.s", "lfo.s", "channel.s", "envelope.s", "voice.s"]

HALVES = 2                  # the LFO pool's halves (lfo.s)


def layout():
    """The program's constants, name -> value, from the generated header."""
    values = {}
    for name, value in re.findall(r"inline constexpr int (\w+) = (\d+);", open(HEADER).read()):
        values[name] = int(value)
    return values


def pointer_writes():
    cp = layout()
    writes = []
    for half in range(HALVES):
        writes.append((cp["lfo_sets"] + half * cp["set_size"] + cp["base"], cp["lfos"] + half * cp["lfos_a_half"] * cp["lfo_size"]))
    for channel in range(cp["channel_count"]):      # the loops' counts are the program's (counts.s)
        record = cp["channels"] + channel * cp["channel_size"]
        writes.append((record + cp["lfo1"], cp["lfos"]))
        writes.append((record + cp["lfo2"], cp["lfos"] + cp["lfos_a_half"] * cp["lfo_size"]))
        writes.append((record + cp["sink_block"], cp["channel_sinks"] + channel * cp["channel_sink_size"]))
        writes.append((record + cp["bend"], 0))
    for voice in range(cp["voice_count"]):
        record = cp["voices"] + voice * cp["voice_size"]
        writes.append((record + cp["channel"], cp["channels"]))
        writes.append((record + cp["sink"], cp["sinks"] + voice * cp["voice_sinks_size"]))
    return writes


def flags(writes):
    return [f for address, raw in writes for f in ("-w", "0x%03x=0x%x" % (address, raw))]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["writes", "script", "match"])
    parser.add_argument("dump", nargs="?", help="match: the chip's registers (chip_check.py's output)")
    parser.add_argument("-f", "--fill", default="7", help="the fill's seed")
    args = parser.parse_args()
    writes = flags(pointer_writes())
    if args.mode == "writes":
        print(" ".join(writes))
        return 0
    sources = [os.path.join(PROGRAMS, s) for s in SOURCES]
    if args.mode == "script":
        command = [CSP, "script"] + sources + ["-f", args.fill] + writes
    else:
        if not args.dump:
            parser.error("match needs the chip's dump")
        command = [CSP, "match"] + sources + ["-c", args.dump, "-f", args.fill] + writes
    return subprocess.run(command).returncode


if __name__ == "__main__":
    sys.exit(main())
