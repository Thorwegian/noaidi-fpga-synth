#!/usr/bin/env python3
"""Mash test (#97, Thor 2026-09-11): chaos in, silence out.

"Mashing (random keys, random velocities, random CCs) should, after
some time, stabilise." This is the standing regression for stuck
voices / engine wedges: run it AFTER ANY CHANGE TO THE SYNTH.

Sequence:
  1. reset BOTH boards - FPGA SRAM reload, then ESP32 reboot (the
     standing order rule), console logger restarted
  2. mash over BLE: random note on/offs (tracked), random velocities,
     random CCs at random values
  3. release every held note with a plain note-off (deliberately NOT
     CC 123 - the panic path would mask exactly the bug we hunt)
  4. wait for the release tails (D/R can be long under random CCs)
     by polling 1 s captures from the digital S/PDIF input
  5. PASS = the capture reaches AC-SILENCE: zero samples deviate from
     each channel's parked constant, and that constant (DC) is within
     4 LSB of zero. The DC tolerance exists because the output tilt's
     truncating integrator parks a ~1-LSB DC after signal decays
     (#102) - pure DC, inaudible, and NOT a stuck voice. Anything
     with actual AC energy at the deadline = FAIL, spectrum printed.

CCs excluded from randomization - each would MASK a stuck voice:
  7 (volume could land at 0), 119 (test tone replaces the mix),
  120 (all sound off), 123 (all notes off).

    ~/.noaidi-blenv/bin/python3 tools/mash_check.py [--mash SECS]
        [--settle SECS] [--seed N] [--skip-reset]
"""
import argparse
import glob
import os
import random
import subprocess
import sys
import time
import wave

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIO_DEV = "hw:1,0"
RATE = 48000
EXCLUDED_CCS = {7, 119, 120, 123}


def db(x):
    return 20.0 * np.log10(max(float(x), 1e-12))


def find_esp():
    for p in sorted(glob.glob("/dev/ttyACM*")):
        r = subprocess.run(["udevadm", "info", "-q", "property", "-n", p],
                           capture_output=True, text=True)
        if "Espressif" in r.stdout:
            return p
    return None


def reset_boards():
    print("[reset] FPGA SRAM reload ...")
    r = subprocess.run(["make", "-C", os.path.join(REPO, "rtl"), "sram"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-500:], r.stderr[-500:])
        raise SystemExit("FPGA reload failed")
    esp = find_esp()
    if not esp:
        raise SystemExit("no Espressif console port found")
    subprocess.run(["pkill", "-f", "console_logger"], capture_output=True)
    subprocess.run(["fuser", "-k", esp], capture_output=True)
    time.sleep(1)
    import serial
    p = serial.Serial(esp, 115200, timeout=0.2)
    p.dtr = False
    p.rts = True
    time.sleep(0.1)
    p.rts = False
    buf = b""
    t0 = time.time()
    while time.time() - t0 < 8:
        buf += p.read(4096)
        if b"play the keyboard" in buf:
            break
    p.close()
    for line in buf.decode("utf-8", "replace").splitlines():
        if "noaidi fw" in line:
            print("[reset]", line.strip())
    subprocess.Popen(
        ["setsid", "nohup", "bash", os.path.join(REPO, "tools",
                                                 "console_logger.sh")],
        stdout=open("/tmp/console_logger.err", "w"),
        stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
        start_new_session=True)
    time.sleep(2)
    print("[reset] both boards reset, logger restarted")


def capture_probe(secs=1):
    """Return (rms_db, ac_nonzero, (dc_l, dc_r)) from a short capture.

    ac_nonzero counts samples that deviate from their channel's median
    - the parked-DC-tolerant silence metric (#102: the output tilt
    parks a ~1-LSB DC; that is not a stuck voice)."""
    subprocess.run(["amixer", "-c", "1", "cset", "numid=16", "2"],
                   capture_output=True)
    subprocess.run(["amixer", "-c", "1", "cset", "numid=13", "on"],
                   capture_output=True)
    out = "/tmp/mash_probe.wav"
    subprocess.run(["arecord", "-D", AUDIO_DEV, "-f", "S16_LE",
                    "-r", str(RATE), "-c", "2", "-t", "wav", "-q",
                    "-d", str(secs), out], capture_output=True)
    try:
        w = wave.open(out)
        d = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
        w.close()
    except Exception:
        return None
    if d.size < RATE:
        return None
    st = d.reshape(-1, 2)
    dcs = (int(np.median(st[:, 0])), int(np.median(st[:, 1])))
    ac = int((st[:, 0] != dcs[0]).sum() + (st[:, 1] != dcs[1]).sum())
    f = d.astype(np.float64) / 32768.0
    return (db(np.sqrt((f ** 2).mean())), ac, dcs)


def spectrum_lines(path="/tmp/mash_probe.wav", count=4):
    w = wave.open(path)
    d = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    w.close()
    left = d.reshape(-1, 2)[:, 0].astype(np.float64) / 32768.0
    n = 16384
    if len(left) < n:
        return
    frames = left[:len(left) // n * n].reshape(-1, n) * np.hanning(n)
    spec = np.abs(np.fft.rfft(frames, axis=1)).mean(axis=0)
    freqs = np.fft.rfftfreq(n, 1 / RATE)
    seen = []
    for b in np.argsort(spec)[::-1]:
        f = freqs[b]
        if f < 20 or any(abs(f - x) < 12 for x in seen):
            continue
        seen.append(f)
        print(f"  residual line {f:8.1f} Hz  {db(spec[b] / (n / 4)):+7.1f} dB")
        if len(seen) >= count:
            break


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mash", type=int, default=30,
                    help="seconds of chaos (default 30)")
    ap.add_argument("--settle", type=int, default=180,
                    help="max seconds to wait for silence (default 180)")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--skip-reset", action="store_true",
                    help="skip the both-board reset (NOT the standard run)")
    args = ap.parse_args()

    seed = args.seed if args.seed is not None else int(time.time()) & 0xFFFF
    random.seed(seed)
    print(f"[mash] seed {seed} (pass --seed {seed} to reproduce)")

    if not args.skip_reset:
        reset_boards()

    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True)
    held = set()
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

        print(f"[mash] {args.mash} s of random notes/velocities/CCs ...")
        t0 = time.time()
        events = 0
        while time.time() - t0 < args.mash:
            r = random.random()
            if r < 0.35 and held:
                n = random.choice(sorted(held))
                held.discard(n)
                send(NoteOffEvent(note=n, channel=0, velocity=0))
            elif r < 0.70:
                n = random.randint(24, 96)
                if n not in held:
                    held.add(n)
                    send(NoteOnEvent(note=n, channel=0,
                                     velocity=random.randint(1, 127)))
            else:
                cc = random.randint(1, 127)
                while cc in EXCLUDED_CCS:
                    cc = random.randint(1, 127)
                send(ControlChangeEvent(channel=0, param=cc,
                                        value=random.randint(0, 127)))
            events += 1
            time.sleep(random.uniform(0.004, 0.02))
        print(f"[mash] {events} events sent, releasing "
              f"{len(held)} held notes (plain note-offs)")
        for n in sorted(held):
            send(NoteOffEvent(note=n, channel=0, velocity=0))
            time.sleep(0.005)
        held.clear()
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
        print("[ble] disconnected + untrusted")

    print(f"[settle] waiting for digital silence "
          f"(max {args.settle} s; D/R tails may be long) ...")
    t0 = time.time()
    while time.time() - t0 < args.settle:
        probe = capture_probe(1)
        if probe is None:
            print("  capture failed (no S/PDIF lock?)")
            time.sleep(5)
            continue
        rms, ac, dcs = probe
        print(f"  t=+{time.time() - t0:5.0f}s  RMS {rms:+7.1f} dBFS  "
              f"AC-deviating {ac}  DC {dcs}")
        if ac == 0 and max(abs(dcs[0]), abs(dcs[1])) <= 4:
            print(f"RESULT: PASS - AC-silent after mash (seed {seed}; "
                  f"parked DC {dcs} is the known #102 tilt residual)")
            return 0
        time.sleep(5)
    print("RESULT: FAIL - still sounding at the deadline "
          f"(seed {seed}); residual spectrum:")
    spectrum_lines()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
