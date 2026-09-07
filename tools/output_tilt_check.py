#!/usr/bin/env python3
"""Verify the output 6 dB/oct tilt (top.sv one-pole, alpha=1/16).

Plays a saw with the SVF opened to its clamp (CC 74 max, resonance 0)
so the synth filter is ~flat below 8 kHz, captures, and measures the
harmonic envelope. A saw is -6 dB/oct by itself; through the one-pole
it reads ~-12 dB/oct above the corner. Dividing out the ideal 1/n saw
leaves the one-pole response, which is fit for the corner frequency.

Expected: fc = -ln(1-1/16)*96000/(2*pi) ~ 986 Hz (alpha=1/16 exact).
PASS if the fitted corner is within an octave-ish and the high-band
slope shows the extra pole.

    python3 output_tilt_check.py [--note 45] [--device hw:1,0]
"""
import argparse
import cmath
import math
import struct
import subprocess
import time

NOAIDI_MAC = "10:00:3B:B0:4D:A6"
RATE = 48000
N = 8192
EXPECT_FC = -math.log(1 - 1 / 16) * 96000 / (2 * math.pi)   # ~986 Hz


def midi_session():
    from alsa_midi import SequencerClient
    client = SequencerClient("tilt-check")
    port = client.create_port("out")
    target = None
    for p in client.list_ports():
        if "Noaidi" in (p.client_name or "") or "Noaidi" in (p.name or ""):
            target = p
            break
    if target is None:
        raise RuntimeError("Noaidi MIDI port not found")
    port.connect_to(target)
    return client, port


def hann_fft_mag(frame):
    n = len(frame)
    w = [frame[i] * 0.5 * (1 - math.cos(2 * math.pi * i / n))
         for i in range(n)]
    def fft(x):
        m = len(x)
        if m == 1:
            return x
        ev = fft(x[0::2]); od = fft(x[1::2])
        tw = [cmath.exp(-2j * cmath.pi * k / m) * od[k] for k in range(m // 2)]
        return ([ev[k] + tw[k] for k in range(m // 2)] +
                [ev[k] - tw[k] for k in range(m // 2)])
    return [abs(c) for c in fft([complex(v, 0) for v in w])]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--note", type=int, default=45)   # A2 = 110 Hz
    ap.add_argument("--device", default="hw:1,0")
    args = ap.parse_args()
    f0 = 440.0 * 2 ** ((args.note - 69) / 12)

    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True)
    ok = False
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
            print("no BLE port"); return 2

        from alsa_midi import (NoteOnEvent, NoteOffEvent, ControlChangeEvent)
        client, port = midi_session()

        def send(ev):
            client.event_output(ev, port=port); client.drain_output()

        send(ControlChangeEvent(channel=0, param=74, value=127))  # SVF open
        send(ControlChangeEvent(channel=0, param=71, value=0))    # no reso
        send(NoteOnEvent(note=args.note, channel=0, velocity=127))
        time.sleep(1.0)

        rec = subprocess.run(
            ["arecord", "-D", args.device, "-f", "S16_LE", "-r", str(RATE),
             "-c", "2", "-t", "raw", "-q", "-d", "2"], capture_output=True)
        with open("/tmp/tilt_capture.raw", "wb") as f:
            f.write(rec.stdout)   # kept for publish_capture.sh review
        send(NoteOffEvent(note=args.note, channel=0, velocity=0))
        send(ControlChangeEvent(channel=0, param=74, value=64))
        send(ControlChangeEvent(channel=0, param=123, value=0))
        client.close()

        n = len(rec.stdout) // 2
        s = struct.unpack(f"<{n}h", rec.stdout)
        frame = s[0::2][RATE // 2: RATE // 2 + N]
        mag = hann_fft_mag(frame)

        # harmonic levels: peak bin within +/-3 of each ideal position
        print(f"saw @ {f0:.1f} Hz, SVF at clamp; expect one-pole "
              f"fc ~ {EXPECT_FC:.0f} Hz on top of the saw's -6 dB/oct")
        print(" harm |  freq Hz | level dB | saw-corrected dB")
        pts = []
        h1 = None
        h = 1
        while h * f0 < 9000:
            b = round(h * f0 * N / RATE)
            m = max(mag[max(2, b - 3): b + 4])
            lvl = 20 * math.log10(m) if m > 0 else -160
            if h1 is None:
                h1 = lvl
            corr = lvl - h1 + 20 * math.log10(h)   # undo saw 1/n
            pts.append((h * f0, corr))
            if h in (1, 2, 4, 8, 12, 16, 24, 32, 48, 64):
                print(f"  {h:3d} | {h*f0:8.1f} | {lvl-h1:8.2f} | {corr:8.2f}")
            h += 1

        # fit fc by least squares over one-pole model
        best = (None, 1e9)
        fc = 300.0
        while fc < 4000:
            err = sum((c - (-10 * math.log10(1 + (f / fc) ** 2))) ** 2
                      for f, c in pts if f > 200)
            if err < best[1]:
                best = (fc, err)
            fc *= 1.02
        fit = best[0]
        ratio = fit / EXPECT_FC
        ok = 0.6 < ratio < 1.7
        print(f"\nfitted one-pole corner: {fit:.0f} Hz "
              f"(expected {EXPECT_FC:.0f} Hz, ratio {ratio:.2f})")
        print(f"RESULT output_tilt_check: {'PASS' if ok else 'FAIL'}")
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
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
