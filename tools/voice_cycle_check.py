#!/usr/bin/env python3
"""Voice-pool uniformity check (the every-32-note-ons bug, 2026-09-10).

Thor: 'every 32 note-ons, the cutoff goes low.' Cause: the engine
prod queue overflowed during the init burst and silently dropped the
TAIL - voices 30/31's amp-envelope configs - so notes landing on
those voices played at the gain floor. LRU voice cycling made it
periodic with NUM_VOICES.

This plays 36 short identical notes (a full pool cycle plus wrap),
measures each one's level, and asserts the spread stays inside 8 dB -
a dead or floor-gained voice shows up as a 20+ dB dropout. Also
watches the console for the init-drop tripwire.

    ~/.noaidi-blenv/bin/python3 tools/voice_cycle_check.py
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


def level(seconds=0.4):
    rec = subprocess.run(
        ["arecord", "-D", AUDIO_DEV, "-f", "S16_LE", "-r", str(RATE),
         "-c", "2", "-t", "raw", "-q", "-d", "1"],
        capture_output=True)
    n = len(rec.stdout) // 2
    s = struct.unpack(f"<{n}h", rec.stdout)
    ch = s[0::2][:int(RATE * seconds)]
    dc = sum(ch) / len(ch)
    acc = sum((v - dc) * (v - dc) for v in ch)
    rms = math.sqrt(acc / len(ch))
    return 20 * math.log10(rms / 32768.0) if rms > 0 else -96.0


def main():
    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True)
    levels = []
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

        send(ControlChangeEvent(channel=0, param=87, value=0))  # vel off
        time.sleep(0.1)
        for i in range(N_NOTES):
            send(NoteOnEvent(note=NOTE, channel=0, velocity=100))
            time.sleep(0.25)
            lv = level(0.4)
            send(NoteOffEvent(note=NOTE, channel=0, velocity=0))
            send(ControlChangeEvent(channel=0, param=120, value=0))
            time.sleep(0.25)
            levels.append(lv)
            flag = "  <-- LOW" if levels and lv < max(levels) - 8 else ""
            print(f"note {i + 1:2d}: {lv:6.1f} dBFS{flag}")
        send(ControlChangeEvent(channel=0, param=87, value=64))
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

    spread = max(levels) - min(levels)
    print(f"=== {len(levels)} notes, level spread {spread:.1f} dB "
          f"(max {max(levels):.1f} / min {min(levels):.1f}) ===")
    if spread > 8:
        print("FAIL: voice pool not uniform - a voice is dead or floored")
        return 1
    print("PASS: all voices in the pool sound at uniform level")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
