#!/usr/bin/env python3
"""Match 1, board side: does the master limiter hold windowed RMS?

Thor's acceptance criterion, verbatim: "the RMS over a window long enough
to cover about a 20 Hz sine wave cycle-long window should not deviate by
more than ~3 dB". 20 Hz -> 50 ms windows.

This is the metric that FAILED on 2026-09-18 with the pre-pipeline
limiter: regn-telt.wav "sputters like the background noise on a vinyl
record". The sim bench (tb_prog_limiter) reported 0.23 dB on the same
design class. That disagreement is the whole point of the match.

    ~/.noaidi-blenv/bin/python3 tools/hil_limiter_rms.py

Capture hygiene per AGENTS.md: CC 120 between steps, every CC the
measurement depends on is set explicitly, BLE disconnected + untrusted on
exit (#82).
"""
import struct
import subprocess
import sys
import time

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC

AUDIO_DEV = "hw:1,0"
RATE = 48000
WIN_MS = 50.0                      # one 20 Hz cycle
CHORD = (45, 52, 57, 61, 64)       # 5 notes, drive the bus hard

# Hard-driven patch: the limiter must be doing real work, or the test
# proves nothing (a bench that stays under threshold measures unity gain).
PATCH = [
    (20, 0),    # osc1 saw
    (24, 0),    # mix to osc1
    (26, 64),   # voice mode 7+1 UNISON -- 8 elements per note. Plain mode
                # peaked at -15.7 dBFS with a 5-note chord, i.e. ~15 dB
                # BELOW the -1 dBFS threshold, so the limiter never engaged
                # and the test measured chord beating instead. The limiter
                # must be doing real work or this proves nothing.
    (27, 24),   # some unison detune: perfectly coherent elements is not a
                # realistic worst case and invites exact cancellation
    (28, 0),    # spread centered: keep the energy on both channels
    (86, 0), (87, 0),
    (29, 0),    # LP
    (30, 127),  # 24 dB/oct
    (74, 96),   # cutoff open
    (71, 40),   # moderate resonance -- testing the LIMITER, not the filter
    (73, 127),  # fastest attack
    (75, 0), (79, 127), (72, 100),
    (107, 64), (77, 0), (110, 0),
    (7, 127),   # volume MAX: force the limiter to act
    (10, 64),
]


def capture(seconds):
    rec = subprocess.run(
        ["arecord", "-D", AUDIO_DEV, "-f", "S16_LE", "-r", str(RATE),
         "-c", "2", "-t", "raw", "-q", "-d", str(int(seconds))],
        capture_output=True)
    n = len(rec.stdout) // 2
    s = struct.unpack(f"<{n}h", rec.stdout)
    return np.array(s[0::2], dtype=float)


def windowed_rms(x, skip_ms=300.0):
    """-> (max deviation dB between adjacent windows, per-window dBFS).

    Skips the attack transient: the criterion is about the limiter
    SPUTTERING in steady state, not about note onset."""
    n = int(RATE * WIN_MS / 1000.0)
    x = x[int(RATE * skip_ms / 1000.0):]
    nw = len(x) // n
    if nw < 3:
        return None, []
    db = []
    for i in range(nw):
        w = x[i * n:(i + 1) * n]
        r = np.sqrt(np.mean(w * w))
        db.append(20 * np.log10(max(r, 1e-9) / 32768.0))
    jumps = [abs(db[i + 1] - db[i]) for i in range(len(db) - 1)]
    return max(jumps), db


def main():
    print(f"[metric] windowed RMS, {WIN_MS:.0f} ms windows (one 20 Hz cycle)")
    print("[pass]   max adjacent-window deviation <= 3.0 dB")
    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True)
    try:
        print(f"[ble] connecting {NOAIDI_MAC} ...")
        bt(f"connect {NOAIDI_MAC}", btctl)
        if not wait_for_alsa_port():
            print("FAIL: BLE ALSA port never appeared")
            return 2
        client, port = open_midi_out()
        from alsa_midi import NoteOnEvent, NoteOffEvent, ControlChangeEvent

        def send(ev):
            client.event_output(ev, port=port)
            client.drain_output()

        def cc(num, val):
            send(ControlChangeEvent(channel=0, param=num, value=val))

        for num, val in PATCH:
            cc(num, val)
            time.sleep(0.03)
        time.sleep(0.2)

        cc(120, 0)
        time.sleep(0.4)
        for n in CHORD:
            send(NoteOnEvent(note=n, channel=0, velocity=127))
        time.sleep(0.4)
        x = capture(2)
        for n in CHORD:
            send(NoteOffEvent(note=n, channel=0, velocity=0))
        cc(120, 0)

        if len(x) < 4096 or np.abs(x).max() == 0:
            print("ABORT: digital silence with the chord held -- rig failure,")
            print("  not a measurement. Check /tmp/noaidi_console.log.")
            return 3

        dev, db = windowed_rms(x)
        if dev is None:
            print("ABORT: capture too short to window")
            return 3
        peak = 20 * np.log10(np.abs(x).max() / 32768.0)
        print(f"[capture] {len(x)/RATE:.1f} s, peak {peak:.1f} dBFS, "
              f"{len(db)} windows")

        # VALIDITY GATE: the limiter holds the bus at -1 dBFS, so a capture
        # peaking well below that never engaged it and this is not a
        # measurement of the limiter at all -- it is a measurement of the
        # chord's own envelope. Report INVALID, never pass or fail.
        if peak < -3.0:
            print(f"[verdict] INVALID: peak {peak:.1f} dBFS is below the "
                  f"-1 dBFS threshold, so the limiter never engaged.")
            print("  This measures chord beating, not the limiter. Drive "
                  "harder (more unison / more notes) and re-run.")
            return 4
        print(f"[result]  RMS {min(db):.1f} .. {max(db):.1f} dBFS, "
              f"max adjacent deviation {dev:.2f} dB")
        print(f"[verdict] {'PASS' if dev <= 3.0 else 'FAIL'} "
              f"({dev:.2f} dB vs 3.0 dB criterion)")
        cc(7, 100)
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
