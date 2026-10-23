#!/usr/bin/env python3
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
"""Does CC 87 actually scale the MOD envelope's amount?

A velocity sweep with CC 107 at centre cannot answer this: the mod
envelope's depth is then zero and CC 87 has nothing to scale.
The sweep then shows no brightness trend, which is correct and uninformative
-- a detector measured against a signal it cannot see. So this check opens
the depth first.

So: give the mod envelope real depth, then check the centroid tracks velocity
at amount 127 and does NOT at amount 0. Level is reported too, because a
centroid measured on a note near the noise floor is measuring hiss -- at
amount 127 a vel-1 note came out at -69 dB and its centroid was pure noise.
"""
import subprocess
import sys
import time
import wave

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC

RATE, DEV, NOTE = 48000, "hw:1,0", 60
VELS = (24, 64, 100, 127)
FLOOR_DB = -45.0          # below this the centroid is noise, not the note


def capture(path, secs):
    subprocess.run(["arecord", "-D", DEV, "-f", "S16_LE", "-r", str(RATE),
                    "-c", "2", "-t", "wav", "-q", "-d", str(int(secs)), path],
                   capture_output=True)
    w = wave.open(path)
    d = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16); w.close()
    return d.reshape(-1, 2)[:, 0].astype(np.float64) / 32768.0


def measure(x):
    db = 20 * np.log10(max(np.sqrt((x ** 2).mean()), 1e-12))
    n = (len(x) - 2048) // 256 + 1
    if n < 16:
        return db, float("nan")
    idx = np.arange(2048)[None, :] + 256 * np.arange(n)[:, None]
    sp = np.abs(np.fft.rfft(x[idx] * np.hanning(2048), axis=1))
    f = np.fft.rfftfreq(2048, 1 / RATE)
    e = sp.sum(axis=1) + 1e-12
    c = (sp * f).sum(axis=1) / e
    return db, float(np.max(c[:len(c) // 2]))   # the PEAK of the filter sweep


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

        def note(vel):
            client.event_output(NoteOnEvent(note=NOTE, channel=0, velocity=vel),
                                port=port)
            client.drain_output(); time.sleep(0.2)
            x = capture(f"/tmp/vf{vel}.wav", 2)
            client.event_output(NoteOffEvent(note=NOTE, channel=0, velocity=0),
                               port=port)
            client.drain_output(); cc(120, 0); time.sleep(0.4)
            return measure(x)

        cc(123, 0); cc(120, 0); time.sleep(1.2)

        # A real mod-env amount to scale, and the amp amount pinned OFF so the
        # level stays high enough that the centroid means something.
        print("  CC107=96 (mod-env depth up), CC86=0 (amp amount off so level")
        print("  stays measurable), CC74=70, sweeping CC87\n")
        out = {}
        for amt in (0, 127):
            cc(107, 96); cc(74, 70); cc(86, 0); cc(87, amt)
            time.sleep(0.3)
            print(f"  CC87 = {amt}")
            rows = []
            for v in VELS:
                db, pk = note(v)
                flag = "  (near floor, centroid unreliable)" if db < FLOOR_DB else ""
                rows.append((v, db, pk))
                print(f"    vel {v:3d}   rms {db:+6.1f} dB   peak centroid "
                      f"{pk:7.0f} Hz{flag}")
            out[amt] = rows
            print()

        print("  VERDICT")
        for amt in (0, 127):
            good = [pk for _, db, pk in out[amt] if db >= FLOOR_DB]
            span = (max(good) - min(good)) if len(good) >= 2 else float("nan")
            print(f"    CC87={amt:<4d} peak-centroid span across velocity "
                  f"{span:7.0f} Hz  ({len(good)} usable note(s))")
            out[amt] = span

        if np.isnan(out[0]) or np.isnan(out[127]):
            print("    -> too few usable notes; inconclusive")
            rc = 1
        elif out[127] > out[0] * 2 and out[127] > 200:
            print("    -> PASS: velocity scales the MOD envelope's excursion, "
                  "and does not when the amount is 0")
        else:
            print("    -> FAIL: CC 87 is not changing the MOD envelope's "
                  "velocity response")
            rc = 1

        cc(86, 64); cc(87, 64); cc(107, 87); cc(123, 0); cc(120, 0)   # boot values
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
