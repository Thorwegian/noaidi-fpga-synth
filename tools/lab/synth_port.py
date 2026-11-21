#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""synth_port.py -- the ALSA sequencer port the synth is reached at.

The synth is its own USB MIDI device now (the socket marked USB), so the port
is found by the client's name, never by a number: the CH345 adapter this
replaced was 16:0, and a number that still pointed at it would drive nothing
while looking like it worked.
"""

import re
import subprocess

# The ALSA client is named after the USB product string, Model 1; the Noaidi
# prefix is kept so a prototype named otherwise is still found.
SYNTH_CLIENTS = ("Model 1", "Noaidi")


def find_synth_rawmidi():
    """The synth's rawmidi port as amidi wants it (hw:C,D,S), or None.

    The sequencer address above is what a MIDI library speaks; the raw
    interface is a different name for the same device, found by the card's
    name in amidi's own listing rather than by a number that can move."""
    try:
        listing = subprocess.run(["amidi", "-l"], capture_output=True,
                                 text=True).stdout
    except OSError:
        return None
    for line in listing.splitlines():
        if any(name in line for name in SYNTH_CLIENTS):
            found = re.search(r"hw:(\d+,\d+,\d+)", line)
            if found:
                return "hw:" + found.group(1)
    return None


def find_synth_port():
    """The synth's first ALSA sequencer port as client:port, or None when no
    client of that name is on the sequencer."""
    client = None
    try:
        with open("/proc/asound/seq/clients", "r", errors="replace") as clients:
            for line in clients:
                found = re.match(r'Client\s+(\d+)\s*:\s*"([^"]*)"', line)
                if found:
                    client = (int(found.group(1)), found.group(2))
                    continue
                port = re.match(r"\s*Port\s+(\d+)\s*:", line)
                if port and client and any(client[1].startswith(name)
                                           for name in SYNTH_CLIENTS):
                    return "%d:%s" % (client[0], port.group(1))
    except OSError:
        pass
    return None
