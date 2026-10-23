#!/usr/bin/env python3
"""Parameter feedback (#279): a Program Change moves the surface's knobs.

    Copyright © 2026 Thor H. Linløkken <thj@thj.no>
    License: CERN-OHL-S v2

Over the real Linux path (BlueZ's MIDI plugin, the ALSA port "Noaidi
Bluetooth"), with the CH345 into the panel port as the keyboard's side:

  1. A Program Change sent into the panel port makes the synth send the whole
     patch as CCs on BLE: every patch CC of docs/midi_schema.md exactly once
     (the RPN's select bytes twice), within 2 s.
  2. The values are the loaded patch's: the fields with plain laws (waves,
     filter type and slope, voice mode, volume, velocity amounts) are read
     from the program's .toml and compared.
  3. A patch CC sent into the panel port comes back out on BLE (feedback to
     the other surface); one sent over BLE does not (no echo).

The dump's CC list below is cc_map::dump()'s order; the test reports what is
missing or doubled by number.

    ~/.noaidi-blenv/bin/python3 tools/lab/ble/feedback_check.py [--program 1] [--toml app/storage/Patches/Factory/Pads/Galaxy.toml]
"""
import argparse
import os
import subprocess
import sys
import time
import tomllib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ble_midi_fuzz import NOAIDI_MAC, bt  # noqa: E402
from midi_tx_check import CONNECT_SECONDS, Console, describe, open_ports, received  # noqa: E402

# cc_map::dump()'s messages, in order (the RPN select bytes appear twice).
DUMP = [7, 10, 101, 100, 6, 101, 100,
        20, 14, 15, 25, 21, 22, 23, 85, 24, 26, 27, 28,
        29, 30, 74, 106, 71, 31,
        73, 75, 79, 72, 86,
        102, 103, 104, 105, 108, 107, 87,
        113, 114, 76, 77, 115,
        111, 112, 109, 110, 116]

# The storage format's names (app/main/patch_units.c) and the switch
# positions the panel shows for them (cc_map's four-way 0/32/64/96, three-way
# 0/64/127).
WAVES = {"saw": 0, "pulse": 32, "triangle": 64, "sine": 96}
STRUCTURES = {"1+1": 0, "7+1": 64, "4+4": 127}
FILTERS = {"lowpass": 0, "bandpass": 64, "highpass": 127}


def expected_from_toml(path):
    """The CC values the plain laws give for the file's fields."""
    with open(path, "rb") as f:
        doc = tomllib.load(f)
    want = {}
    try:
        want[20] = WAVES[doc["osc"][0]["wave"]]
        want[21] = WAVES[doc["osc"][1]["wave"]]
    except (KeyError, IndexError, TypeError):
        pass
    try:
        want[29] = FILTERS[doc["filter"]["type"]]
        want[30] = 127 if doc["filter"]["slope"] == 24 else 0
    except (KeyError, TypeError):
        pass
    try:
        want[26] = STRUCTURES[doc["voice"]["structure"]]
    except (KeyError, TypeError):
        pass
    return want


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/dev/ttyACM0", help="the ESP32 console")
    ap.add_argument("--program", type=int, default=1, help="the Program Change to send (bank 0)")
    ap.add_argument("--toml", default=None, help="the program's patch file, for the value check")
    ap.add_argument("--no-reset", action="store_true")
    args = ap.parse_args()

    from alsa_midi import ControlChangeEvent, ProgramChangeEvent

    want = expected_from_toml(args.toml) if args.toml else {}

    cap = Console(args.port, reset=not args.no_reset)
    cap.start()
    time.sleep(3.0)

    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
    failures = []
    client = None
    try:
        print(f"[ble] connecting {NOAIDI_MAC}, {CONNECT_SECONDS:.0f} s for BlueZ ...")
        bt(f"connect {NOAIDI_MAC}", btctl)
        time.sleep(CONNECT_SECONDS)
        client, panel, out, inp = open_ports()

        def send(port, ev):
            client.event_output(ev, port=port)
            client.drain_output()

        # the subscription itself brings a dump (a surface that joins): drain it
        joined = received(client, 2.0)
        print(f"[join] {len(joined)} messages on subscribing (the patch as the surface joins)")

        # 1. the Program Change into the panel port: the whole patch on BLE
        send(panel, ProgramChangeEvent(channel=0, value=args.program))
        events = received(client, 2.5)
        got = [(e.param, e.value) for e in events if isinstance(e, ControlChangeEvent)]
        print(f"[dump] program {args.program}: {len(got)} CCs on BLE within 2.5 s (want {len(DUMP)})")
        counts = {}
        for cc, _ in got:
            counts[cc] = counts.get(cc, 0) + 1
        for cc in sorted(set(DUMP)):
            allowed = DUMP.count(cc)
            if counts.get(cc, 0) != allowed:
                failures.append(f"CC {cc}: {counts.get(cc, 0)} times, want {allowed}")
        for cc in sorted(counts):
            if cc not in DUMP:
                failures.append(f"CC {cc} is not a patch CC and was sent")
        order = [cc for cc, _ in got]
        if order != DUMP and not failures:
            failures.append("the CCs came in another order than cc_map::dump()")

        # 2. the values of the plain-law fields
        values = dict(got)
        for cc, value in sorted(want.items()):
            if values.get(cc) != value:
                failures.append(f"CC {cc} = {values.get(cc)}, the patch file says {value}")
        if want:
            print(f"[values] {len(want)} fields compared with {args.toml}")

        # 3. feedback of a CC from the panel port, no echo of one over BLE
        received(client, 0.2)
        send(panel, ControlChangeEvent(channel=0, param=74, value=90))
        back = [describe(e) for e in received(client, 1.5)]
        print(f"[fwd] panel cc 74=90 -> BLE got {back or 'nothing'}")
        if "cc 74=90" not in back:
            failures.append("a CC from the panel port was not sent on to BLE")
        send(out, ControlChangeEvent(channel=0, param=71, value=20))
        echo = [describe(e) for e in received(client, 1.0)]
        print(f"[echo] BLE cc 71=20 -> BLE got {echo or 'nothing'}")
        if echo:
            failures.append(f"the BLE surface heard itself: {echo}")
    finally:
        if client is not None:
            client.close()
        try:
            bt(f"disconnect {NOAIDI_MAC}", btctl)
            time.sleep(1.5)
            bt(f"untrust {NOAIDI_MAC}", btctl)
            time.sleep(0.5)
            btctl.stdin.close()
        except Exception:
            pass
        btctl.terminate()
        subprocess.run(["bluetoothctl", "disconnect", NOAIDI_MAC], capture_output=True, timeout=10)
        subprocess.run(["bluetoothctl", "untrust", NOAIDI_MAC], capture_output=True, timeout=10)
        cap.stop()
        print("[ble] disconnected + untrusted (cleanup)")

    if failures:
        print("FAIL:")
        for f in failures:
            print("  -", f)
        return 1
    print("PASS: the patch reaches the surface as CCs, once each, with the file's values")
    return 0


if __name__ == "__main__":
    sys.exit(main())
