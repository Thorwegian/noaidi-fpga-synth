#!/usr/bin/env python3
"""Filter pain test (#43): measure where high resonance turns to BRRR.

Thor's repro recipe (2026-09-10, panel screenshot): a 7+1 patch with
velocity fully OFF, MOD env off, cutoff CC74=52 + 100% key track -
the corner rides a constant ~1 octave BELOW the fundamental, which he
found glitches hardest. Only resonance and the 12/24 dB slope vary.
Reported by ear: stable to reso ~35 at 24 dB/oct, ~70 at 12 dB/oct;
beyond that it "clips and goes into a BRRR glitchy kind of sound".

This sweeps CC 71 at both slopes and measures, per step:
  peak/RMS dBFS, crest, and FLAT-TOP fraction - the share of samples
  within 2% of that capture's own peak. A clean resonant tone keeps a
  tiny fraction; hard saturation parks the waveform at the rails and
  the fraction jumps. DC removed per #81; CC 120 between steps per
  the capture-hygiene rule.

    ~/.noaidi-blenv/bin/python3 tools/filter_pain_check.py [cutoff_cc]

cutoff_cc overrides CC 74 (default 52 = Thor's recipe, corner ~1 oct
below the fundamental). Run with e.g. 96 to probe the BRIGHT corner -
hypothesis (Thor 2026-09-10: the physical slider on a bright patch
could near-max resonance, "just glassy"): SVF stress is the
low-cutoff/high-Q corner, where integrator states scale ~1/K into
the clamps; high fc keeps states small and stable.

BLE transport; console untouched (the polite logger keeps running).
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

# Thor's screenshot state, verbatim (only 71/30 vary in the sweep)
PATCH = [
    (20, 0), (14, 64), (15, 64), (25, 64),          # osc1: saw, centered
    (21, 96), (22, 64), (23, 64), (85, 64),         # osc2: sine, unison
    (24, 64), (26, 64), (27, 24), (28, 127),        # balance/7+1/spread
    (74, 52), (106, 0), (29, 0), (31, 64),          # cutoff -1 oct, LP, KT 100%
    (73, 45), (75, 91), (79, 120), (72, 107),       # amp env
    (102, 51), (103, 82), (104, 0), (105, 66),      # mod env (S=0)
    (107, 64),                                      # env->cutoff OFF
    (76, 64), (77, 16), (113, 64),                  # vibrato default
    (109, 64), (110, 0), (111, 64), (112, 0),       # LFO2 off
    (7, 73), (10, 64), (86, 0), (87, 0),            # vol, pan, VELOCITY OFF
]

RESO_STEPS = [0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, 127]


def capture(seconds=1.0):
    rec = subprocess.run(
        ["arecord", "-D", AUDIO_DEV, "-f", "S16_LE", "-r", str(RATE),
         "-c", "2", "-t", "raw", "-q", "-d", str(int(seconds))],
        capture_output=True)
    n = len(rec.stdout) // 2
    s = struct.unpack(f"<{n}h", rec.stdout)
    ch = s[0::2]
    dc = sum(ch) / len(ch)
    ch = [v - dc for v in ch]
    peak = max(max(ch), -min(ch))
    rms = math.sqrt(sum(v * v for v in ch) / len(ch))
    def db(x): return 20 * math.log10(x / 32768.0) if x > 0 else -96.0
    flat = sum(1 for v in ch if abs(v) >= 0.98 * peak) / len(ch) if peak else 0
    return db(peak), db(rms), db(peak) - db(rms), flat


def main():
    cutoff = int(sys.argv[1]) if len(sys.argv) > 1 else 52
    patch = [(n, cutoff if n == 74 else v) for n, v in PATCH]
    print(f"[patch] cutoff CC74 = {cutoff}")
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
        from alsa_midi import (NoteOnEvent, NoteOffEvent,
                               ControlChangeEvent)

        def send(ev):
            client.event_output(ev, port=port)
            client.drain_output()

        def cc(num, val):
            send(ControlChangeEvent(channel=0, param=num, value=val))

        for num, val in patch:
            cc(num, val)
            time.sleep(0.03)

        for slope_name, slope_val in (("24dB", 127), ("12dB", 0)):
            cc(30, slope_val)
            time.sleep(0.2)
            print(f"\n=== slope {slope_name} ===")
            print(" cc71 |  peak dBFS |  rms dBFS | crest dB | flat-top %")
            for r in RESO_STEPS:
                cc(71, r)
                time.sleep(0.15)
                send(NoteOnEvent(note=NOTE, channel=0, velocity=100))
                time.sleep(0.5)
                pk, rm, crest, flat = capture(1.0)
                send(NoteOffEvent(note=NOTE, channel=0, velocity=0))
                cc(120, 0)                    # hard mute between steps
                time.sleep(0.3)
                print(f" {r:4d} | {pk:9.1f}  | {rm:8.1f}  | {crest:7.2f}  |"
                      f" {flat * 100:8.3f}")
        cc(71, 4)                             # restore boot resonance
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
