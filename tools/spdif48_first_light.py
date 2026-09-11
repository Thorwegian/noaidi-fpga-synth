#!/usr/bin/env python3
"""First-light check for the LED-TOSLINK digital capture path (#101).

The FPGA's second S/PDIF transmitter (48 kHz, pin 86) drives a red LED
taped into the ICUSBAUDIO7D optical input. This script proves the
receiver locks and the path is digital end to end:

  1. flip the CM106 capture source Line -> IEC958 In
  2. enable the gateware test tone (CC 119: full-scale 1500 Hz sine,
     the #81 purity reference - it replaces BOTH outputs, so the 48 kHz
     transmitter carries it too)
  3. capture and FFT: at 48 kHz the tone sits EXACTLY on bin 32 of a
     1024-point frame - coherent, no window needed
  4. capture again with the tone off: a locked digital path delivers
     bit-exact zeros, something the analog path never once managed
  5. leave the rig in its resting state: tone off, capture source
     IEC958 In — the DEFAULT since 2026-09-11 (Thor: the 48 kHz
     digital path is the primary measurement path)

PASS = tone on bin 32 at better than -6 dBFS. The off-bin floor and
the silence capture are printed for the issue record.

    ~/.noaidi-blenv/bin/python3 tools/spdif48_first_light.py

Lock-probe mode (no Bluetooth, no tone): the S/PDIF carrier runs
continuously whatever the audio content, and the CM106 returns
Input/output error from a capture read whenever its receiver has no
lock - so a short capture that RETURNS DATA is itself the lock proof.
Polls until lock or the deadline; meant to run while the LED is being
seated and adjusted in the optical port:

    ~/.noaidi-blenv/bin/python3 tools/spdif48_first_light.py --lock-probe 600
"""
import subprocess
import sys
import time
import wave

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC

AUDIO_DEV = "hw:1,0"
RATE = 48000
TONE_HZ = 1500
TONE_BIN = TONE_HZ * 1024 // RATE          # 32

# CM106 mixer controls (amixer -c 1): numid=16 is the 4-way capture
# source (0 Mic, 1 Line, 2 'IEC958 In', 3 Mixer), numid=13 the
# IEC958 capture switch. IEC958 is the DEFAULT capture source
# (Thor, 2026-09-11) — asserted at start AND on exit, so a crashed
# run can never strand the rig on the analog path.
def set_capture(source_item, iec_switch):
    subprocess.run(["amixer", "-c", "1", "cset", "numid=16",
                    str(source_item)], capture_output=True)
    subprocess.run(["amixer", "-c", "1", "cset", "numid=13",
                    "on" if iec_switch else "off"], capture_output=True)


def rec(path, secs):
    """Capture; returns True only if real frames arrived (the CM106
    aborts the read with I/O error when its S/PDIF receiver has no
    lock, leaving a header-only WAV)."""
    r = subprocess.run(["arecord", "-D", AUDIO_DEV, "-f", "S16_LE",
                        "-r", str(RATE), "-c", "2", "-t", "wav", "-q",
                        "-d", str(secs), path], capture_output=True)
    try:
        w = wave.open(path)
        frames = w.getnframes()
        w.close()
    except Exception:
        return False
    if r.returncode != 0 or frames < int(RATE * secs * 0.5):
        err = r.stderr.decode(errors="replace").strip()
        print(f"[rec] no data ({frames} frames){': ' + err if err else ''}")
        return False
    return True


def load(path):
    w = wave.open(path)
    d = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    w.close()
    return d.reshape(-1, 2).astype(np.float64) / 32768.0


def db(x):
    return 20.0 * np.log10(max(float(x), 1e-12))


def analyze_tone(path):
    d = load(path)
    left = d[:, 0]
    frames = left[12000:12000 + 1024 * 32].reshape(-1, 1024)
    spec = np.abs(np.fft.rfft(frames, axis=1)).mean(axis=0) / 512.0
    peak_bin = int(np.argmax(spec[1:]) + 1)
    peak_db = db(spec[peak_bin])
    print(f"[tone] peak bin {peak_bin} ({peak_bin * RATE / 1024:.1f} Hz) "
          f"at {peak_db:+.1f} dBFS  (expected bin {TONE_BIN})")
    for h in (2, 3, 4):
        b = TONE_BIN * h
        if b < len(spec):
            print(f"[tone] harmonic {h}: {db(spec[b]) - peak_db:+.1f} dBc")
    mask = np.ones(len(spec), bool)
    mask[0] = False
    for h in range(1, 8):
        b = TONE_BIN * h
        if b < len(spec):
            mask[max(b - 2, 0):b + 3] = False
    print(f"[tone] median off-bin floor: {db(np.median(spec[mask])):+.1f} dBFS")
    print(f"[tone] max|sample| {np.abs(d).max():.6f}  "
          f"RMS {db(np.sqrt((left ** 2).mean())):+.1f} dBFS")
    return peak_bin, peak_db


def analyze_silence(path):
    d = load(path)
    peak = float(np.abs(d).max())
    nz = int(np.count_nonzero(d))
    print(f"[silence] max|sample| {peak:.6f}  nonzero samples {nz}/{d.size}")
    return peak


def lock_probe(deadline_s):
    """Poll for S/PDIF lock with short captures; no Bluetooth, no tone.
    Prints one line per state change so it can run while the LED is
    physically adjusted. Returns 0 on lock."""
    set_capture(2, True)                    # IEC958 In
    locked = False
    t0 = time.time()
    try:
        while time.time() - t0 < deadline_s:
            got = rec("/tmp/spdif48_probe.wav", 1)
            if got and not locked:
                print(f"LOCK at +{time.time() - t0:.0f}s", flush=True)
                locked = True
            elif not got and locked:
                print(f"lock LOST at +{time.time() - t0:.0f}s", flush=True)
                locked = False
            elif not got:
                print(f"no lock +{time.time() - t0:.0f}s", flush=True)
            if locked:
                return 0
            time.sleep(1)
    finally:
        set_capture(2, True)                # IEC958 stays the default
    print("RESULT: FAIL - no lock before deadline")
    return 1


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--lock-probe":
        secs = int(sys.argv[2]) if len(sys.argv) > 2 else 300
        return lock_probe(secs)
    set_capture(2, True)                    # IEC958 In
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
        from alsa_midi import ControlChangeEvent

        def cc(num, val):
            client.event_output(
                ControlChangeEvent(channel=0, param=num, value=val),
                port=port)
            client.drain_output()

        cc(119, 127)                        # test tone on
        time.sleep(0.5)
        got_tone = rec("/tmp/spdif48_tone.wav", 2)
        cc(119, 0)                          # test tone off
        time.sleep(0.5)
        got_sil = rec("/tmp/spdif48_silence.wav", 1)
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
        set_capture(2, True)                # IEC958 stays the default
        print("[ble] disconnected + untrusted; capture source IEC958")

    if not got_tone:
        print("RESULT: FAIL - receiver delivered no data (no S/PDIF "
              "lock: check LED seating/polarity/joints)")
        return 1
    peak_bin, peak_db = analyze_tone("/tmp/spdif48_tone.wav")
    if got_sil:
        analyze_silence("/tmp/spdif48_silence.wav")
    ok = peak_bin == TONE_BIN and peak_db > -6.0
    print("RESULT: " + ("PASS - optical link locked, digital path live"
                        if ok else "FAIL - no coherent tone on bin 32"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
