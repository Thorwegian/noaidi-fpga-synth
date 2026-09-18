#!/usr/bin/env python3
"""FPGA-in-the-loop filter distortion probe (#123, for #121 M3).

WHY NOT flat-top: tools/filter_pain_check.py measures the share of samples
at the output rails. That detects clipping of the MASTER bus -- but the
element's internal sat_q414 clip is attenuated downstream by the per-element
gain and the master limiter, so it never reaches the rails. Since the #121
master limiter landed, a rail metric reports "clean" no matter how badly an
element distorts. It is now blind to the thing we are hunting.

THE METRIC: intermodulation. A LINEAR filter driven by two notes can only
emit harmonics of those two notes -- n*f1 and m*f2. Any energy elsewhere is
proof of a nonlinearity, and it survives downstream attenuation (turning a
distorted signal down leaves it distorted). So:

    IMD_dB = 10*log10( energy NOT on either harmonic series / energy on them )

A clean filter sits at the capture noise floor; internal clipping lifts it
tens of dB. Two notes a tritone apart (irrational ratio) keep the two
harmonic series from colliding, so intermod products land in clear space.

Model prediction under test (2026-09-18): the failure corner is the cutoff
sitting ON the fundamental, where the resonant peak catches the whole note
instead of one weak harmonic -- the reso_att LUT is indexed by RESONANCE
ONLY and is calibrated where the peak caught the 11th harmonic, so it
under-attenuates by ~20 dB here. CC74 = 64 with 100% key tracking puts the
cutoff on the key-tracked base, i.e. on the fundamental.

    ~/.noaidi-blenv/bin/python3 tools/hil_filter_imd.py [slope]

slope: 24 (default) or 12. Capture hygiene per AGENTS.md: CC 120 between
steps, every CC the measurement depends on is set explicitly, BLE is
disconnected and untrusted on exit (#82).
"""
import struct
import subprocess
import sys
import time

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC

AUDIO_DEV = "hw:1,0"
RATE = 48000
NOTES = (57, 63)                      # A3 220.0 Hz + Eb4 311.127 Hz: tritone
FREQS = tuple(440.0 * 2 ** ((n - 69) / 12) for n in NOTES)

# A deliberately PLAIN patch: one saw oscillator, no unison detune or
# spread, velocity off, no LFO/mod-env movement -- so the filter is the
# only thing that can bend the spectrum.
PATCH = [
    (20, 0),    # osc1 = saw
    (24, 0),    # mix hard to osc1 (osc2 hard-muted at the rail)
    (26, 0),    # voice mode: plain
    (27, 0),    # unison detune OFF
    (28, 0),    # unison spread: centered
    (86, 0),    # velocity -> amp OFF
    (87, 0),    # velocity -> cutoff OFF
    (31, 64),   # key tracking 100% (cutoff tracks the note)
    (29, 0),    # filter type LP
    (73, 127),  # amp attack fastest
    (75, 0),    # amp decay longest
    (79, 127),  # amp sustain full  -> a steady tone
    (72, 100),  # amp release
    (107, 64),  # MOD env depth centre = OFF
    (77, 0),    # vibrato depth 0
    (110, 0),   # LFO2 depth 0
    (7, 127),   # volume MAX -- drive hard on purpose: the #121 master limiter
                # holds the bus at -1 dBFS, so this buys the full 16 bits of
                # capture instead of measuring distortion down in the noise
                # (the first run sat at -47..-78 dBFS = ~6 bits of signal).
    (10, 64),   # pan centre
]

CUTOFFS = [40, 52, 58, 64, 70, 76, 88]     # 64 = cutoff ON the fundamental
RESOS = [64, 96, 127]


def capture(seconds=1.0):
    rec = subprocess.run(
        ["arecord", "-D", AUDIO_DEV, "-f", "S16_LE", "-r", str(RATE),
         "-c", "2", "-t", "raw", "-q", "-d", str(int(seconds))],
        capture_output=True)
    n = len(rec.stdout) // 2
    s = struct.unpack(f"<{n}h", rec.stdout)
    return np.array(s[0::2], dtype=float)      # left channel


def spectrum(x):
    """-> (harmonic energy, non-harmonic energy, peak dBFS)."""
    x = x - x.mean()                            # DC per #81
    peak = np.abs(x).max()
    pk_db = 20 * np.log10(peak / 32768.0) if peak > 0 else -96.0
    X = np.abs(np.fft.rfft(x * np.hanning(len(x)))) ** 2
    df = RATE / len(x)
    onh = np.zeros(len(X), dtype=bool)
    for f0 in FREQS:                            # mark both harmonic series
        for k in range(1, int((RATE / 2) / f0) + 1):
            b = int(round(k * f0 / df))
            if b < len(X):
                onh[max(0, b - 3):b + 4] = True
    onh[:int(25 / df)] = True                   # ignore DC / subsonic
    return X[onh].sum(), X[~onh].sum(), pk_db


def analyse(x, noise_non=0.0):
    """-> (imd_dB, peak_dBFS, trustworthy).

    NOISE-FLOOR CORRECTED: the capture's own noise lands in the
    non-harmonic bins, so a near-silent point (filter closed) otherwise
    reports huge IMD purely because the harmonic term vanished -- the
    first run's '+26 dB worst case' was exactly that, measured at
    -78 dBFS. Subtract the measured silent-capture energy and flag any
    point too quiet to trust."""
    if len(x) < 4096:
        return 99.0, -96.0, False
    harm, non, pk_db = spectrum(x)
    non = max(non - noise_non, 0.0)
    if harm <= 0:
        return 99.0, pk_db, False
    return 10 * np.log10(max(non, 1e-30) / harm), pk_db, pk_db > -55.0


def main():
    slope = int(sys.argv[1]) if len(sys.argv) > 1 else 24
    slope_val = 127 if slope == 24 else 0
    print(f"[patch] plain saw, 2 notes {NOTES} = {FREQS[0]:.1f}/{FREQS[1]:.1f} Hz, "
          f"slope {slope} dB/oct")
    print("[metric] IMD dB = non-harmonic / harmonic energy "
          "(linear filter -> noise floor; clipping -> tens of dB higher)")
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
        from alsa_midi import NoteOnEvent, NoteOffEvent, ControlChangeEvent

        def send(ev):
            client.event_output(ev, port=port)
            client.drain_output()

        def cc(num, val):
            send(ControlChangeEvent(channel=0, param=num, value=val))

        for num, val in PATCH:
            cc(num, val)
            time.sleep(0.03)
        cc(30, slope_val)
        time.sleep(0.2)

        # noise-floor reference: silence, same chain, same analysis bins
        cc(120, 0)
        time.sleep(0.5)
        _, noise_non, noise_pk = spectrum(capture(1.0))
        print(f"[noise] silent capture: peak {noise_pk:.1f} dBFS "
              f"(its non-harmonic energy is subtracted from every point)")

        def play_and_capture(co, r):
            """One grid point. Returns the capture, or None if the RIG died
            (digital silence while a note is held = BLE dropped / voice wedge
            / ESP reboot -- NOT a measurement, so never report it as one)."""
            cc(74, co); cc(71, r)
            time.sleep(0.15)
            for n in NOTES:
                send(NoteOnEvent(note=n, channel=0, velocity=100))
            time.sleep(0.5)
            x = capture(1.0)
            for n in NOTES:
                send(NoteOffEvent(note=n, channel=0, velocity=0))
            cc(120, 0)
            time.sleep(0.3)
            if len(x) < 4096 or np.abs(x).max() == 0:
                return None
            return x

        # PREFLIGHT: prove the rig makes sound before trusting any grid.
        # (A previous run silently went mute partway and produced a whole
        # table of meaningless numbers.)
        pf = play_and_capture(76, 96)
        if pf is None:
            print("ABORT: preflight produced DIGITAL SILENCE with a note held.")
            print("  The rig is not playing -- BLE dropped, voices wedged, or")
            print("  the ESP rebooted (engine mutes on boot until reprogrammed).")
            print("  Check /tmp/noaidi_console.log; reboot the ESP and retry.")
            return 3
        print(f"[preflight] ok: {spectrum(pf)[2]:.1f} dBFS with notes held")

        print("\n  IMD dB (peak dBFS in brackets) -- higher IMD = more distortion")
        print("  cutoff |" + "".join(f"   reso {r:3d}    " for r in RESOS))
        worst = (-99.0, None)
        for co in CUTOFFS:
            cells = []
            for r in RESOS:
                x = play_and_capture(co, r)
                if x is None:                    # rig died -- stop, don't invent data
                    print(f"    {co:4d} | RIG WENT SILENT at reso {r} -- aborting.")
                    print("  Digital silence with a note held is a rig failure, not a")
                    print("  measurement. Everything above this line is still valid.")
                    raise SystemExit(4)
                imd, pk, ok = analyse(x, noise_non)
                if ok and imd > worst[0]:
                    worst = (imd, (co, r))
                cells.append(f" {imd:+6.1f} ({pk:5.1f}){'' if ok else '?'}")
            mark = "  <- cutoff ON the fundamental" if co == 64 else ""
            print(f"    {co:4d} |" + "".join(cells) + mark)
        print("  ('?' = too quiet to trust: below -55 dBFS the 16-bit capture "
              "noise swamps the measurement)")
        if worst[1]:
            print(f"\n  worst TRUSTED: IMD {worst[0]:+.1f} dB at cutoff "
                  f"CC74={worst[1][0]}, reso CC71={worst[1][1]}")
        else:
            print("\n  no point was loud enough to trust -- raise the level")
        cc(71, 4)
        cc(30, 127)
        cc(74, 64)
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
