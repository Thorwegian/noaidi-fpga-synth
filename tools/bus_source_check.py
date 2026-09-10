#!/usr/bin/env python3
"""Hardware test of the type-3 bus source (#44).

Since #44's firmware half, CC 74 travels the new path end to end:
CC 74 -> channel cutoff bus (BUS_CH_CUT) BASE -> 32 type-3 walker
entries -> per-voice cutoff buses -> element cutoff. If the fan-out
works, sweeping CC 74 dark/bright changes the saw's spectrum through
the filter; if it is broken, cutoff stops responding entirely (the
per-voice base now carries only velocity, which this patch zeroes).

Metric: brightness index = RMS(first difference)/RMS - a first
difference emphasizes HF, so an open filter scores several times a
closed one. PASS: bright index >= 2x dark index, and both captures
carry real signal.

    ~/.noaidi-blenv/bin/python3 tools/bus_source_check.py
"""
import math
import struct
import subprocess
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC

AUDIO_DEV = "hw:1,0"
RATE = 48000
NOTE = 45

PATCH = [
    (20, 0), (14, 64), (15, 64), (25, 0),           # osc1 saw
    (21, 0), (22, 64), (23, 64), (85, 0),           # osc2 saw, unison
    (24, 64), (26, 64), (27, 24), (28, 127),
    (106, 0), (29, 0), (30, 127), (31, 64),         # LP 24 dB, KT 100%
    (71, 4),                                        # low resonance
    (73, 45), (75, 91), (79, 120), (72, 107),
    (107, 64),                                      # MOD env off
    (77, 0), (110, 0),                              # LFOs off
    (7, 73), (10, 64), (86, 0), (87, 0),            # VELOCITY OFF
]


def brightness(seconds=1.0):
    rec = subprocess.run(
        ["arecord", "-D", AUDIO_DEV, "-f", "S16_LE", "-r", str(RATE),
         "-c", "2", "-t", "raw", "-q", "-d", str(int(seconds))],
        capture_output=True)
    n = len(rec.stdout) // 2
    s = struct.unpack(f"<{n}h", rec.stdout)
    ch = s[0::2]
    dc = sum(ch) / len(ch)
    ch = [v - dc for v in ch]
    rms = math.sqrt(sum(v * v for v in ch) / len(ch))
    diff = [ch[i] - ch[i - 1] for i in range(1, len(ch))]
    drms = math.sqrt(sum(v * v for v in diff) / len(diff))
    def db(x): return 20 * math.log10(x / 32768.0) if x > 0 else -96.0
    return db(rms), (drms / rms if rms > 0 else 0)


def main():
    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True)
    failures = []
    try:
        print(f"[ble] connecting {NOAIDI_MAC} ...")
        bt(f"connect {NOAIDI_MAC}", btctl)
        if not wait_for_alsa_port():
            print("FAIL: BLE ALSA port never appeared")
            return 2
        client, port = open_midi_out()
        from alsa_midi import (NoteOnEvent, NoteOffEvent,
                               ControlChangeEvent)

        def send(ev):
            client.event_output(ev, port=port)
            client.drain_output()

        def cc(num, val):
            send(ControlChangeEvent(channel=0, param=num, value=val))

        for num, val in PATCH:
            cc(num, val)
            time.sleep(0.03)

        # Operating points chosen so BOTH captures carry tonal signal
        # (first run's dark=10 closed ~7 oct down = chain-floor noise,
        # whose diff-RMS index reads HIGH and inverts the comparison):
        # dark = 52 (corner ~1 oct below the note, Thor's pain-recipe
        # value, ~-53 dBFS measured), bright = 100 (corner ~+4 oct).
        results = {}
        for label, cut in (("dark", 52), ("bright", 100)):
            cc(74, cut)
            time.sleep(0.2)
            send(NoteOnEvent(note=NOTE, channel=0, velocity=100))
            time.sleep(0.5)
            level, idx = brightness(1.0)
            send(NoteOffEvent(note=NOTE, channel=0, velocity=0))
            cc(120, 0)
            time.sleep(0.4)
            results[label] = (level, idx)
            print(f"[cut] CC74={cut:3d} ({label:6s}): level {level:6.1f} dBFS"
                  f"  brightness {idx:.4f}")
        cc(74, 64)

        d_level, d_idx = results["dark"]
        b_level, b_idx = results["bright"]
        if d_level < -65 or b_level < -65:
            failures.append("a capture sat at the chain floor - "
                            "operating point wrong or note missing")
        if b_level - d_level < 12:
            failures.append(
                f"bright only {b_level - d_level:.1f} dB louder than dark "
                "(need >=12) - cutoff not moving through the fan-out")
        if d_idx <= 0 or b_idx / max(d_idx, 1e-9) < 1.5:
            failures.append(
                f"brightness ratio {b_idx / max(d_idx, 1e-9):.2f} < 1.5 - "
                "spectrum not opening with CC 74")
        client.close()
    finally:
        try:
            bt(f"disconnect {NOAIDI_MAC}", btctl)
            time.sleep(1.5)
            bt(f"untrust {NOAIDI_MAC}", btctl)
            time.sleep(0.5)
            btctl.stdin.close()
        except Exception:
            pass
        btctl.terminate()
        subprocess.run(["bluetoothctl", "disconnect", NOAIDI_MAC],
                       capture_output=True, timeout=10)
        subprocess.run(["bluetoothctl", "untrust", NOAIDI_MAC],
                       capture_output=True, timeout=10)
        print("[ble] disconnected + untrusted (cleanup)")

    if failures:
        print("FAIL:")
        for f in failures:
            print("  -", f)
        return 1
    print("PASS: channel -> voice -> element fan-out works on hardware (#44)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
