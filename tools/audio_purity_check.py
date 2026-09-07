#!/usr/bin/env python3
"""Audio-chain purity self-check (issue #81, Thor's criterion).

Enables the gateware test tone over BLE MIDI (CC 119): a full-scale
sine with a 512-sample period at 96 kHz = 187.5 Hz, which at 48 kHz
capture lands EXACTLY on bin 4 of a 1024-point FFT — coherent, no
window, harmonics on exact bins (8, 12, 16, ...).

Criterion: any harmonic above 1/4096 of the fundamental (−72.2 dBc;
2^12 — audible bit-resolution trouble starts around 12 bits) rings
alarm bells. Passing means the analog gain structure is clean enough
and no further gain-staging work is needed.

    python3 audio_purity_check.py [--device hw:1,0] [--keep-tone]

Needs the Noaidi connected via BLE (BlueZ MIDI plugin -> ALSA port)
and the capture chain on the Line input. Always disconnects/untrusts
BLE when done; disables the tone unless --keep-tone.
"""
import argparse
import cmath
import math
import struct
import subprocess
import sys
import time

NOAIDI_MAC = "10:00:3B:B0:4D:A6"
RATE = 48000
N = 1024                 # FFT size: 187.5 Hz -> bin 4 exactly
FUND_BIN = 4
LIMIT = 1.0 / 4096.0     # -72.25 dBc


def send_cc119(value):
    from alsa_midi import SequencerClient, ControlChangeEvent
    client = SequencerClient("purity-check")
    port = client.create_port("out")
    target = None
    for p in client.list_ports():
        if "Noaidi" in (p.client_name or "") or "Noaidi" in (p.name or ""):
            target = p
            break
    if target is None:
        raise RuntimeError("Noaidi ALSA MIDI port not found (BLE up?)")
    port.connect_to(target)
    client.event_output(ControlChangeEvent(channel=0, param=119, value=value),
                        port=port)
    client.drain_output()
    time.sleep(0.3)
    client.close()


def capture(device, seconds):
    rec = subprocess.run(
        ["arecord", "-D", device, "-f", "S16_LE", "-r", str(RATE),
         "-c", "2", "-t", "raw", "-q", "-d", str(seconds)],
        capture_output=True)
    n = len(rec.stdout) // 2
    s = struct.unpack(f"<{n}h", rec.stdout)
    return s[0::2], s[1::2]


def dft_mag(frame):
    """Magnitudes of a 1024-point DFT (recursive radix-2)."""
    def fft(x):
        n = len(x)
        if n == 1:
            return x
        ev = fft(x[0::2]); od = fft(x[1::2])
        tw = [cmath.exp(-2j * cmath.pi * k / n) * od[k] for k in range(n // 2)]
        return ([ev[k] + tw[k] for k in range(n // 2)] +
                [ev[k] - tw[k] for k in range(n // 2)])
    return [abs(c) for c in fft([complex(v, 0) for v in frame])]


def analyze(name, ch):
    # Skip the first second (tone settling, S/PDIF receiver lock), then
    # analyze several frames and take the worst case.
    start = RATE
    worst = None
    for f in range(6):
        frame = ch[start + f * N: start + (f + 1) * N]
        if len(frame) < N:
            break
        mag = dft_mag(frame)
        fund = mag[FUND_BIN]
        if fund <= 0:
            continue
        # harmonics: bins 8,12,...; also track the biggest NON-harmonic
        # spur anywhere above bin 1 (excluding fund's immediate skirt)
        harms = []
        h = 2
        while h * FUND_BIN < N // 2:
            harms.append((h, mag[h * FUND_BIN] / fund))
            h += 1
        spur_bin, spur = max(
            ((b, mag[b] / fund) for b in range(2, N // 2)
             if abs(b - FUND_BIN) > 1 and b % FUND_BIN != 0),
            key=lambda t: t[1])
        cand = {
            "fund": fund,
            "harms": harms,
            "worst_h": max(harms, key=lambda t: t[1]),
            "spur": (spur_bin, spur),
        }
        if worst is None or cand["worst_h"][1] > worst["worst_h"][1]:
            worst = cand
    if worst is None:
        print(f"{name}: no signal on bin {FUND_BIN}!")
        return False

    def dbc(r):
        return 20 * math.log10(r) if r > 0 else -140.0

    hn, hr = worst["worst_h"]
    sb, sr = worst["spur"]
    fund_dbfs = 20 * math.log10(worst["fund"] / (N / 2) / 32768.0)
    ok = hr <= LIMIT
    print(f"{name}: fundamental {fund_dbfs:6.2f} dBFS @ 187.5 Hz")
    print(f"   worst harmonic  H{hn} ({hn*187.5:7.1f} Hz): {dbc(hr):7.2f} dBc "
          f"(limit {dbc(LIMIT):.2f})  {'OK' if ok else 'ALARM'}")
    print(f"   worst other spur bin {sb} ({sb*46.875:7.1f} Hz): {dbc(sr):7.2f} dBc")
    for hh, rr in worst["harms"][:6]:
        print(f"     H{hh}: {dbc(rr):7.2f} dBc")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="hw:1,0")
    ap.add_argument("--keep-tone", action="store_true")
    args = ap.parse_args()

    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True)
    ok = False
    try:
        btctl.stdin.write(f"connect {NOAIDI_MAC}\n"); btctl.stdin.flush()
        t0 = time.time()
        while time.time() - t0 < 20:
            out = subprocess.run(["aconnect", "-l"], capture_output=True,
                                 text=True).stdout
            if "Noaidi" in out:
                break
            time.sleep(0.5)
        else:
            print("BLE/ALSA port never appeared"); return 2

        print("[tone] enabling test tone (CC 119)")
        send_cc119(127)
        time.sleep(0.5)
        left, right = capture(args.device, 3)
        ok_l = analyze("L", left)
        ok_r = analyze("R", right)
        ok = ok_l and ok_r
        if not args.keep_tone:
            print("[tone] disabling")
            send_cc119(0)
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

    print(f"\nRESULT audio_purity_check: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
