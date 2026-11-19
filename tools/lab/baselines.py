#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""The lab's baselines: the presets the acceptance plays, and where each is.

A baseline is a preset of the storage's Presets/Factory/Tests folder, played
through the fixed sequence (baseline_recording.py) and judged against its
benchmark (tools/lab/benchmark/). The folder holds copies made for the lab:
the presets a player voices live elsewhere and move, these do not, so a
benchmark stays valid until its own file here is changed.

The presets are the programs of a bank of their own, the highest bank number
there is (app/storage/banks.toml), and the acceptance loads them the way a
player's controller would: Bank Select, then Program Change.
"""
from collections import namedtuple

TESTS_BANK = 16383                                # Bank Select MSB 127, LSB 127

# program:   the preset's program in the Tests bank
# preset:    its file, from the storage's root
# transpose: semitones added to every note of the sequence
# benchmark: the base name of its reference files in tools/lab/benchmark/
Baseline = namedtuple("Baseline", "program preset transpose benchmark")

BASELINES = {
    "galaxy": Baseline(0, "Presets/Factory/Tests/Galaxy.toml", 0, "baseline_galaxy_d03e915"),
    # a bass, so two octaves down: C3 … C4, and the triad C2 E2 G2
    "powerbass": Baseline(1, "Presets/Factory/Tests/PowerBass.toml", -24, "baseline_powerbass_b158923"),
}


def bank_select(bank):
    """The two Bank Select messages for a bank number, as aseqsend's hex."""
    return ["B0 00 %02X" % (bank >> 7), "B0 20 %02X" % (bank & 0x7F)]
