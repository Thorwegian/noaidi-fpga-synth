#!/usr/bin/env python3
"""Resonance clipping onset measurement (issue #63).

Theory from the RTL: the element audio path clamps at sat_q216 (Q2.16,
+/-2.0) at the FILTER OUTPUTS (S6/S9), upstream of the S10 gain
multiply -- and the oscillator drives the filter at a fixed clamp-12 dB
regardless of gain/volume. Resonance peak gain is ~6 dB per octave of
Q, so internal clipping should begin around r = 2 octaves = CC 71 ~ 16,
independent of volume.

This plays a sustained note over BLE MIDI, steps CC 71 upward, and
captures/analyzes 1 s per step: peak, RMS, crest factor. A clean
resonant tone has a stable crest; the clamp shows up as the peak
plateauing while RMS keeps rising -> crest collapsing, plus harmonic
bloom. Prints a table; the knee is the measured onset.

    python3 reso_clip_sweep.py [--note 45] [--device hw:1,0]
"""
import argparse
import math
import struct
import subprocess
import time

NOAIDI_MAC = "10:00:3B:B0:4D:A6"
RATE = 48000
STEPS = [0, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 80, 96]


def midi_client():
    from alsa_midi import SequencerClient
    client = SequencerClient("reso-sweep")
    port = client.create_port("out")
    target = None
    for p in client.list_ports():
        if "Noaidi" in (p.client_name or "") or "Noaidi" in (p.name or ""):
            target = p
            break
    if target is None:
        raise RuntimeError("Noaidi ALSA MIDI port not found")
    port.connect_to(target)
    return client, port


def capture(device, seconds):
    rec = subprocess.run(
        ["arecord", "-D", device, "-f", "S16_LE", "-r", str(RATE),
         "-c", "2", "-t", "raw", "-q", "-d", str(seconds)],
        capture_output=True)
    n = len(rec.stdout) // 2
    s = struct.unpack(f"<{n}h", rec.stdout)
    return s[0::2]   # left is enough; both carry the same voice halves


def stats(ch):
    # Remove DC first: the analog capture path carries a significant
    # offset (#81, measured 2026-09-09) that inflates peak and RMS.
    dc = sum(ch) / len(ch)
    ch = [v - dc for v in ch]
    peak = max(max(ch), -min(ch))
    rms = math.sqrt(sum(v * v for v in ch) / len(ch))
    def db(x): return 20 * math.log10(x / 32768.0) if x > 0 else -96.0
    return db(peak), db(rms), db(peak) - db(rms)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--note", type=int, default=45)   # A2: harmonics feed fc
    ap.add_argument("--device", default="hw:1,0")
    args = ap.parse_args()

    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True)
    try:
        btctl.stdin.write(f"connect {NOAIDI_MAC}\n"); btctl.stdin.flush()
        t0 = time.time()
        while time.time() - t0 < 20:
            if "Noaidi" in subprocess.run(["aconnect", "-l"],
                                          capture_output=True,
                                          text=True).stdout:
                break
            time.sleep(0.5)
        else:
            print("no BLE/ALSA port"); return 2

        from alsa_midi import (NoteOnEvent, NoteOffEvent, ControlChangeEvent)
        client, port = midi_client()

        def send(ev):
            client.event_output(ev, port=port); client.drain_output()

        print(f"note {args.note}, sustained; CC71 sweep")
        print(" cc71 |  peak dBFS |  rms dBFS | crest dB")
        print("------+------------+-----------+---------")
        send(NoteOnEvent(note=args.note, channel=0, velocity=127))
        time.sleep(0.8)   # attack settles
        for cc in STEPS:
            send(ControlChangeEvent(channel=0, param=71, value=cc))
            time.sleep(0.4)   # coalesced apply + filter settle
            ch = capture(args.device, 1)
            pk, rm, cr = stats(ch)
            print(f"  {cc:3d} |   {pk:7.2f}  |  {rm:7.2f}  |  {cr:5.2f}")
        send(NoteOffEvent(note=args.note, channel=0, velocity=0))
        send(ControlChangeEvent(channel=0, param=71, value=0))
        send(ControlChangeEvent(channel=0, param=123, value=0))
        time.sleep(0.5)
        client.close()
    finally:
        try:
            btctl.stdin.write(f"disconnect {NOAIDI_MAC}\nuntrust {NOAIDI_MAC}\n")
            btctl.stdin.flush(); time.sleep(1.5); btctl.stdin.close()
        except Exception:
            pass
        btctl.terminate()
        subprocess.run(["bluetoothctl", "disconnect", NOAIDI_MAC],
                       capture_output=True, timeout=10)
        subprocess.run(["bluetoothctl", "untrust", NOAIDI_MAC],
                       capture_output=True, timeout=10)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
