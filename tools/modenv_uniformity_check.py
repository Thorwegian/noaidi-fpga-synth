#!/usr/bin/env python3
"""MOD-env uniformity under CC dragging (Thor's 15:14 bug, 2026-09-10).

Thor: with a plucky MOD-env patch, 'random notes have a longer MOD
envelope, probably every 32nd.' Suspected cause: a knob DRAG that
includes a re-render (e.g. PW) wedges the engine task in a long SPI
flush; meanwhile coalesced applies keep pushing 96-write update_mod_env
bursts, the prod queue overflows, and the DROPPED TAIL (= the highest
voices) keeps stale RATES from earlier in the drag.

Reproduction: storm CC 103 (MOD decay, dragged 111 -> 64) interleaved
with CC 25 (PW - forces 256-element re-renders), like a human
twiddling two knobs; then play a full 36-note pool cycle and measure
each note's DECAY RATIO (early RMS 50-200 ms vs late RMS 350-500 ms).
A stale-long voice decays slower = higher late/early ratio.

PASS: decay-ratio spread across the pool <= 6 dB.

    ~/.noaidi-blenv/bin/python3 tools/modenv_uniformity_check.py
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
N_NOTES = 36

PATCH = [
    (20, 0), (21, 0), (26, 0),                      # 2-plain saws
    (74, 40), (31, 64), (30, 127), (71, 4),         # darkish base
    (73, 0), (75, 80), (79, 127), (72, 60),         # amp: instant on
    (102, 40), (104, 0), (105, 60),                 # MOD env: pluck
    (107, 110),                                     # strong env->cutoff
    (77, 0), (110, 0), (86, 0), (87, 0),            # LFOs + velocity off
]


def seg_rms_db(ch, t0, t1):
    seg = ch[int(RATE * t0):int(RATE * t1)]
    dc = sum(seg) / len(seg)
    rms = math.sqrt(sum((v - dc) * (v - dc) for v in seg) / len(seg))
    return 20 * math.log10(rms / 32768.0) if rms > 0 else -96.0


def main():
    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True)
    ratios = []
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

        # The drag storm: MOD decay 111 -> 64 while PW wiggles (forces
        # re-renders) - the two-knob twiddle that wedges the flush.
        print("[storm] dragging CC 103 + CC 25 ...")
        pw = 0
        for v in range(111, 63, -1):
            cc(103, v)
            pw = (pw + 7) & 0x3F
            cc(25, pw)
            time.sleep(0.004)
        cc(103, 64)
        cc(25, 0)
        time.sleep(0.5)

        for i in range(N_NOTES):
            send(NoteOnEvent(note=NOTE, channel=0, velocity=100))
            rec = subprocess.Popen(
                ["arecord", "-D", AUDIO_DEV, "-f", "S16_LE", "-r", str(RATE),
                 "-c", "2", "-t", "raw", "-q", "-d", "1"],
                stdout=subprocess.PIPE)
            out, _ = rec.communicate()
            send(NoteOffEvent(note=NOTE, channel=0, velocity=0))
            cc(120, 0)
            time.sleep(0.25)
            n = len(out) // 2
            s = struct.unpack(f"<{n}h", out)
            ch = s[0::2]
            early = seg_rms_db(ch, 0.05, 0.20)
            late = seg_rms_db(ch, 0.35, 0.50)
            ratios.append(late - early)
            print(f"note {i + 1:2d}: early {early:6.1f}  late {late:6.1f}  "
                  f"decay {late - early:+5.1f} dB")
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

    spread = max(ratios) - min(ratios)
    print(f"=== decay-ratio spread {spread:.1f} dB "
          f"(max {max(ratios):+.1f} / min {min(ratios):+.1f}) ===")
    if spread > 6:
        print("FAIL: MOD envelope not uniform across the pool - "
              "stale RATES on some voice(s)")
        return 1
    print("PASS: MOD envelope uniform across the whole voice pool")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
