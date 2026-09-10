#!/usr/bin/env python3
"""Capture listenable examples of the filter pain zones (#43).

Companion to filter_pain_check.py: same Thor-recipe patch, but records
a few representative (slope, resonance) settings as WAV files for
listening review (publish with tools/publish_capture.sh).

    ~/.noaidi-blenv/bin/python3 tools/pain_capture.py
"""
import subprocess
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC
from filter_pain_check import PATCH, AUDIO_DEV, RATE, NOTE

CASES = [
    ("24dB-reso32-stable",  127, 32),
    ("24dB-reso56-onset",   127, 56),
    ("24dB-reso80-brrr",    127, 80),
    ("12dB-reso104-brrr",     0, 104),
    ("12dB-reso127-anomaly",  0, 127),
]


def main():
    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True)
    files = []
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

        for label, slope, reso in CASES:
            cc(30, slope)
            cc(71, reso)
            time.sleep(0.2)
            out = f"/tmp/pain_{label}.wav"
            send(NoteOnEvent(note=NOTE, channel=0, velocity=100))
            time.sleep(0.3)
            subprocess.run(
                ["arecord", "-D", AUDIO_DEV, "-f", "S16_LE",
                 "-r", str(RATE), "-c", "2", "-t", "wav", "-q",
                 "-d", "3", out], capture_output=True)
            send(NoteOffEvent(note=NOTE, channel=0, velocity=0))
            cc(120, 0)
            time.sleep(0.3)
            files.append(out)
            print(f"[cap] {out}")
        cc(71, 4)
        cc(30, 127)
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
    print("FILES:", " ".join(files))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
