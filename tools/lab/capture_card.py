#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""Set the capture card up before a recording.

The USB capture card comes up on the driver's defaults: the capture source
is whatever the first enum item is, and both capture switches are off. The
saved ALSA state is applied only to a card that is up at boot, so a card
that dies and re-enumerates later keeps the driver's defaults and captures
exact zeros — a take that reads as a silent synth while the board streams.

Selecting the S/PDIF receiver as the capture source and switching capture
on before `arecord` makes a take independent of the order the card and its
saved state came up in.

usage: capture_card.py [--device hw:1,0]
"""
import argparse
import re
import subprocess

SOURCE = "IEC958 In"
SOURCE_CONTROL = "PCM Capture Source"
SWITCHES = ("PCM", "IEC958 In")


def card_of(device):
    """The card number in an ALSA device name, hw:CARD,DEVICE."""
    match = re.match(r"hw:(\d+),\d+$", device)
    if not match:
        raise SystemExit(f"capture_card: {device!r} is not an hw:CARD,DEVICE name")
    return int(match.group(1))


def prepare(device):
    """Point the card at its S/PDIF input and switch capture on, or say why not."""
    card = str(card_of(device))

    def amixer(*args):
        done = subprocess.run(["amixer", "-c", card, *args],
                              capture_output=True, text=True)
        if done.returncode:
            raise SystemExit(f"capture_card: amixer {' '.join(args)}: "
                             f"{done.stderr.strip() or done.stdout.strip()}")
        return done.stdout

    amixer("sset", SOURCE_CONTROL, SOURCE)
    if SOURCE not in amixer("sget", SOURCE_CONTROL):
        raise SystemExit(f"capture_card: the capture source is not {SOURCE}")
    for name in SWITCHES:
        amixer("sset", name, "cap", "on")
        if "[off]" in amixer("sget", name):
            raise SystemExit(f"capture_card: {name}'s capture switch did not come on")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", default="hw:1,0",
                        help="the ALSA capture device of the S/PDIF input")
    args = parser.parse_args()
    prepare(args.device)
    print(f"capture card ready on {args.device}: {SOURCE}, capture on")


if __name__ == "__main__":
    main()
