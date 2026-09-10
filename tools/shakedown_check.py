#!/usr/bin/env python3
"""Automated check for the #91 shakedown batch, over BLE MIDI.

Runs BEFORE Thor's ear pass (his rule, 2026-09-10): drive the synth
through the sanctioned test transport (BLE - the panel port is Open
Stage Control's exclusively), watch the ESP console for ingress and
crashes, and MEASURE the pan implementation on the analog capture
chain: stereo RMS at pan hard-left / center / hard-right.

    ~/.noaidi-blenv/bin/python3 tools/shakedown_check.py

Reuses ble_midi_fuzz.py's helpers (persistent bluetoothctl session,
ALSA port wait, serial capture, disconnect+untrust discipline).
Audio: ICUSBAUDIO7D LINE IN (hw:1,0) per AGENTS.md, DC removed before
RMS (#81). Pass criteria: >=15 dB toward the panned side at the
rails (far side is VOL_MUTEd - the chain floor decides the margin),
<=3 dB imbalance at center.
"""
import struct
import subprocess
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import (SerialCapture, bt, wait_for_alsa_port,
                           open_midi_out, NOAIDI_MAC, CRASH_KEYS)

AUDIO_DEV = "hw:1,0"
RATE = 48000


def esp_port():
    import glob
    for p in glob.glob("/dev/ttyACM*"):
        r = subprocess.run(["udevadm", "info", "-q", "property", "-n", p],
                           capture_output=True, text=True)
        if "ID_VENDOR=Espressif" in r.stdout:
            return p
    return None


def record_stereo(seconds=1.0):
    """Return (rms_l_db, rms_r_db), DC-removed (#81)."""
    rec = subprocess.run(
        ["arecord", "-D", AUDIO_DEV, "-f", "S16_LE", "-r", str(RATE),
         "-c", "2", "-t", "raw", "-q", "-d", str(int(seconds))],
        capture_output=True)
    n = len(rec.stdout) // 2
    s = struct.unpack(f"<{n}h", rec.stdout)
    import math
    def rms_db(ch):
        if not ch:
            return -96.0
        dc = sum(ch) / len(ch)
        acc = sum((v - dc) * (v - dc) for v in ch)
        rms = math.sqrt(acc / len(ch))
        return 20 * math.log10(rms / 32768.0) if rms > 0 else -96.0
    return rms_db(s[0::2]), rms_db(s[1::2])


def main():
    port_dev = esp_port()
    if not port_dev:
        print("FAIL: no ESP console port found")
        return 2
    cap = SerialCapture(port_dev); cap.start()
    time.sleep(4.0)              # capture resets the chip; let boot settle

    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True)
    failures = []
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

        # ---- 1. ingress smoke on every new #91 CC ----
        print("[smoke] CC 10/31/85/107 ...")
        for num, val in ((10, 32), (31, 64), (85, 96), (107, 72)):
            cc(num, val)
            time.sleep(0.15)
        cc(31, 127)              # restore key tracking default

        # ---- 2. measured pan check ----
        results = {}
        for pan in (0, 64, 127):
            cc(10, pan)
            time.sleep(0.2)
            send(NoteOnEvent(note=57, channel=0, velocity=100))
            time.sleep(0.6)      # attack + envelope settle
            l_db, r_db = record_stereo(1.0)
            send(NoteOffEvent(note=57, channel=0, velocity=0))
            results[pan] = (l_db, r_db)
            print(f"[pan] cc10={pan:3d}: L {l_db:6.1f} dBFS  "
                  f"R {r_db:6.1f} dBFS  (L-R {l_db - r_db:+5.1f} dB)")
            time.sleep(0.8)      # release tail out of the next capture

        cc(10, 64)               # restore center
        cc(123, 0)               # all notes off
        client.close()

        l0, r0 = results[0]
        lc, rc_ = results[64]
        l1, r1 = results[127]
        if l0 - r0 < 15:
            failures.append(f"pan LEFT rail: L-R only {l0 - r0:.1f} dB (need >=15)")
        if r1 - l1 < 15:
            failures.append(f"pan RIGHT rail: R-L only {r1 - l1:.1f} dB (need >=15)")
        if abs(lc - rc_) > 3:
            failures.append(f"pan CENTER: |L-R| {abs(lc - rc_):.1f} dB (need <=3)")
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

    time.sleep(1.0); cap.stop(); cap.join(timeout=3)

    echoes = [l for l in cap.lines if "cc " in l or "note_on" in l]
    crash = [l for l in cap.lines if any(k in l for k in CRASH_KEYS)]
    smoke = {num: any(f"num={num:3d}" in l or f"num= {num}" in l
                      for l in cap.lines) for num in (10, 31, 85, 107)}
    for num, seen in smoke.items():
        print(f"[smoke] CC {num} echoed on console: {'yes' if seen else 'NO'}")
        if not seen:
            failures.append(f"CC {num} never echoed on the console")
    if crash:
        failures.append(f"{len(crash)} crash-indicator lines on console")
        for l in crash[-10:]:
            print("CRASH|", l)

    print(f"=== {len(cap.lines)} console lines, {len(echoes)} MIDI echoes ===")
    if failures:
        print("FAIL:")
        for f in failures:
            print("  -", f)
        return 1
    print("PASS: ingress smoke + measured pan all green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
