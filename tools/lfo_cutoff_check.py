#!/usr/bin/env python3
"""Hardware test: LFO2 -> CUTOFF through the send graph (#92/#98).

The first route that NEEDS the bus-sum read: LFO2 (a walker source)
writes the channel cut bus; the 32 per-voice sends relay its
contribution into the voice cutoff buses. With the old firmware-base
read this was invisible by construction - so a measured filter
wobble IS the bus-sum RAM working on silicon.

Method: saw pad, corner mid-dark, velocity off; hold one note 3 s
and slice the capture into 100 ms windows. With LFO2 -> cutoff at
~4 Hz / strong depth the window-RMS must swing (>= 6 dB max/min);
with depth 0 it must sit still (<= 3 dB). Both sides asserted, so a
stuck-open or stuck-closed filter cannot fake a pass.

    ~/.noaidi-blenv/bin/python3 tools/lfo_cutoff_check.py
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
NOTE = 57

PATCH = [
    (20, 0), (21, 0), (26, 0),                      # 2-plain saws
    (74, 48), (31, 64), (30, 127), (71, 4),         # corner mid-dark
    (73, 0), (75, 111), (79, 127), (72, 60),        # amp: instant, held
    (107, 64),                                      # MOD env off
    (77, 0),                                        # LFO1 depth off
    (109, 90),                                      # LFO2 ~4 Hz
    (111, 64),                                      # triangle
    (112, 96),                                      # dest = CUTOFF
    (86, 0), (87, 0),                               # velocity off
]


def window_rms_spread(seconds=3.0, win=0.1):
    rec = subprocess.run(
        ["arecord", "-D", AUDIO_DEV, "-f", "S16_LE", "-r", str(RATE),
         "-c", "2", "-t", "raw", "-q", "-d", str(int(seconds))],
        capture_output=True)
    n = len(rec.stdout) // 2
    s = struct.unpack(f"<{n}h", rec.stdout)
    ch = s[0::2]
    dc = sum(ch) / len(ch)
    ch = [v - dc for v in ch]
    wlen = int(RATE * win)
    dbs = []
    for i in range(0, len(ch) - wlen, wlen):
        seg = ch[i:i + wlen]
        rms = math.sqrt(sum(v * v for v in seg) / wlen)
        dbs.append(20 * math.log10(rms / 32768.0) if rms > 0 else -96.0)
    dbs = dbs[2:]        # skip attack transient windows
    return max(dbs), min(dbs)


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

        results = {}
        for label, depth in (("wobble", 100), ("still", 0)):
            cc(110, depth)
            time.sleep(0.2)
            send(NoteOnEvent(note=NOTE, channel=0, velocity=100))
            time.sleep(0.4)
            hi, lo = window_rms_spread(3.0)
            send(NoteOffEvent(note=NOTE, channel=0, velocity=0))
            cc(120, 0)
            time.sleep(0.4)
            results[label] = hi - lo
            print(f"[lfo] depth={depth:3d} ({label:6s}): window RMS "
                  f"max {hi:6.1f} / min {lo:6.1f} dBFS  swing {hi - lo:.1f} dB")

        cc(112, 0)                     # dest back to PWM (restore path)
        cc(110, 0)
        client.close()

        if results["wobble"] < 6:
            failures.append(f"wobble swing {results['wobble']:.1f} dB < 6 - "
                            "LFO not reaching cutoff through the sends")
        if results["still"] > 3:
            failures.append(f"still swing {results['still']:.1f} dB > 3 - "
                            "wobble without depth (state leak?)")
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
    print("PASS: LFO2 contribution relayed through the send graph (#92)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
