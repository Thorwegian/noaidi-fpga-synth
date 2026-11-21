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

SYNTH_CLIENT = "Noaidi MIDI"


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
                if port and client and client[1] == SYNTH_CLIENT:
                    return "%d:%s" % (client[0], port.group(1))
    except OSError:
        pass
    return None
