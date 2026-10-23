#!/usr/bin/env python3
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
"""Does velocity actually control the envelope amount?

The hil.py probe plays ONE velocity, so it can only say the synth is not
broken -- it cannot speak to the velocity-to-amount mapping at all. This
plays a velocity ramp at three amount settings and checks two properties:

  amt = 0    every velocity must give the SAME level. That is the true-zero /
             isolation rule from design.md: velocity off, full patch amount.
  amt > 0    level must rise MONOTONICALLY with velocity, one-sided, with full
             velocity reaching the same place amt = 0 does (g = 1 at vel 127).

Also reports the spectral centroid, because CC 87 scales the MOD envelope's
depth and that moves the cutoff, so a brightness trend should track velocity
too.
"""
import subprocess
import sys
import time
import wave

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC

RATE, DEV, NOTE = 48000, "hw:1,0", 60
VELS = (1, 24, 48, 72, 100, 127)


def capture(path, secs):
    subprocess.run(["arecord", "-D", DEV, "-f", "S16_LE", "-r", str(RATE),
                    "-c", "2", "-t", "wav", "-q", "-d", str(int(secs)), path],
                   capture_output=True)
    w = wave.open(path)
    d = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16); w.close()
    return d.reshape(-1, 2)[:, 0].astype(np.float64) / 32768.0


def rms_db(x):
    return 20 * np.log10(max(np.sqrt((x ** 2).mean()), 1e-12))


def centroid(x):
    n = (len(x) - 2048) // 256 + 1
    if n < 16:
        return float("nan")
    idx = np.arange(2048)[None, :] + 256 * np.arange(n)[:, None]
    sp = np.abs(np.fft.rfft(x[idx] * np.hanning(2048), axis=1))
    f = np.fft.rfftfreq(2048, 1 / RATE)
    e = sp.sum(axis=1) + 1e-12
    c = (sp * f).sum(axis=1) / e
    return float(np.median(c[len(c) // 8:]))


def main():
    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             text=True)
    client = None
    rc = 0
    try:
        bt(f"connect {NOAIDI_MAC}", btctl)
        if not wait_for_alsa_port():
            print("FAIL: no BLE port"); return 2
        client, port = open_midi_out()
        from alsa_midi import NoteOnEvent, NoteOffEvent, ControlChangeEvent

        def cc(n, v):
            client.event_output(ControlChangeEvent(channel=0, param=n, value=v),
                                port=port)
            client.drain_output(); time.sleep(0.05)

        def note(vel, secs=2.0):
            client.event_output(NoteOnEvent(note=NOTE, channel=0, velocity=vel),
                                port=port)
            client.drain_output(); time.sleep(0.2)
            x = capture(f"/tmp/vel{vel}.wav", secs)
            client.event_output(NoteOffEvent(note=NOTE, channel=0, velocity=0),
                               port=port)
            client.drain_output(); cc(120, 0); time.sleep(0.4)
            return rms_db(x), centroid(x)

        cc(123, 0); cc(120, 0); time.sleep(1.2)

        results = {}
        for amt in (0, 64, 127):
            cc(86, amt); cc(87, amt)
            time.sleep(0.3)
            print(f"  CC86 = CC87 = {amt}")
            rows = []
            for v in VELS:
                db, cen = note(v)
                rows.append((v, db, cen))
                print(f"    vel {v:3d}   rms {db:+6.1f} dB   centroid {cen:7.0f} Hz")
            results[amt] = rows
            print()

        print("  VERDICT")
        # amt = 0: velocity must not matter
        d0 = [db for _, db, _ in results[0]]
        span0 = max(d0) - min(d0)
        ok0 = span0 < 2.0
        print(f"    amt=0    level span across velocity {span0:5.1f} dB   "
              f"{'PASS (velocity OFF)' if ok0 else 'FAIL -- velocity still acts at amount 0'}")

        for amt in (64, 127):
            d = [db for _, db, _ in results[amt]]
            span = max(d) - min(d)
            # monotonic with a small tolerance for capture noise
            mono = all(d[i + 1] >= d[i] - 0.8 for i in range(len(d) - 1))
            print(f"    amt={amt:<4d} level span {span:5.1f} dB, "
                  f"{'monotonic' if mono else 'NOT MONOTONIC'}   "
                  f"{'PASS' if (mono and span > span0 + 1.0) else 'FAIL'}")
            if not (mono and span > span0 + 1.0):
                rc = 1
        if not ok0:
            rc = 1

        # and full velocity should land in the same place regardless of amount
        top = [results[a][-1][1] for a in (0, 64, 127)]
        print(f"    vel 127 across amounts: {top[0]:+.1f} {top[1]:+.1f} "
              f"{top[2]:+.1f} dB   spread {max(top)-min(top):.1f} dB   "
              f"{'PASS (g=1 at full velocity)' if max(top)-min(top) < 2.0 else 'FAIL'}")
        if max(top) - min(top) >= 2.0:
            rc = 1

        cc(86, 64); cc(87, 64); cc(123, 0); cc(120, 0)
    finally:
        try:
            if client is not None:
                client.event_output(ControlChangeEvent(channel=0, param=120, value=0),
                                    port=port)
                client.drain_output(); client.close()
        except Exception:
            pass
        try:
            bt(f"disconnect {NOAIDI_MAC}", btctl); time.sleep(1.5)
            bt(f"untrust {NOAIDI_MAC}", btctl); time.sleep(0.5)
            btctl.stdin.close()
        except Exception:
            pass
        btctl.terminate()
        for c_ in ("disconnect", "untrust"):
            subprocess.run(["bluetoothctl", c_, NOAIDI_MAC], capture_output=True, timeout=10)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
