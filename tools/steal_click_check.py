#!/usr/bin/env python3
"""Measure the amplitude discontinuity when a SOUNDING voice is stolen (#159).

    Copyright (c) 2026 Thor H. Linloekken <thj@thj.no>
    License: CERN-OHL-S v2

The artefact: the amp envelope resets its level to zero when it sees a gate
POSEDGE, so re-gating a voice that is still audible moves that voice's output
to zero inside one control sample (10.417 us).

Two things make this awkward to measure, and both are handled here.

1. The allocator hands out the voice whose gate has been low the LONGEST, so
   with idle voices available it will never steal the one still sounding. The
   pool has to be exhausted first.
2. If the pool is exhausted by 32 loud notes, the voice being truncated is
   only about 1/32 of the signal and its step disappears into the waveform.

So the pool is exhausted by 31 notes at velocity 1 with velocity->amp-amount
at full (CC 86 = 127), which opens their envelopes by well under a decibel
above the silent floor: held, allocated, effectively inaudible. Exactly one
voice is loud -- a note played and released earlier, still in a slow release
tail -- and it is the only candidate the allocator can pick.

The patch uses parabolic-sine oscillators (CC 20/21 = 127) because the default
supersaw contains a full-scale step at every sawtooth wrap, which would swamp
the measurement. A sine sum at these pitches slews by a few percent of full
scale per sample at 48 kHz, so a truncation stands out by an order of
magnitude.

The capture is self-calibrating: the first note-on's arrival in the recording
fixes the offset between wall-clock time and capture time, so the analysis
windows do not depend on guessing arecord's startup latency or BLE jitter.

    ~/.noaidi-blenv/bin/python3 tools/steal_click_check.py [--label NAME]
"""
import argparse
import glob
import os
import subprocess
import sys
import time
import wave

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC

AUDIO_DEV = "hw:1,0"
RATE = 48000
CAPTURE_WAV = "/tmp/steal_click.wav"
CAPTURE_SECS = 4

LOUD_NOTE = 48             # played, released, still sounding when stolen
STEAL_NOTE = 55            # the note-on that steals it
QUIET_NOTES = [n for n in range(60, 92)][:31]   # 31 held, inaudible

SETUP_CCS = [(20, 127),    # osc 1 waveform -> parabolic sine
             (21, 127),    # osc 2 waveform -> parabolic sine
             (86, 127),    # velocity -> amp-env AMOUNT, full authority
             (72, 127),    # amp release -> slowest, so the tail stays loud
             # amp attack: --attack sets this. The FASTEST attack (0) is
             # itself a near-instant rise, so it contributes a step of its
             # own at the new note. A slow attack (e.g. 110) isolates what
             # the fade leaves behind.
             (75, 0),      # amp decay -> fastest
             (79, 127),    # amp sustain -> full level
             (71, 0),      # resonance off
             (74, 110),    # cutoff well open
             (7, 100)]     # volume


def db(x):
    return 20.0 * np.log10(max(float(x), 1e-12))


def find_esp():
    for p in sorted(glob.glob("/dev/ttyACM*")):
        r = subprocess.run(["udevadm", "info", "-q", "property", "-n", p],
                           capture_output=True, text=True)
        if "ID_VENDOR=Espressif" in r.stdout:
            return p
    return None


def reboot_esp():
    """CC state persists across runs, and this script changes ten of them, so
    every run starts from a freshly booted default patch."""
    port = find_esp()
    if port is None:
        print("  no ESP port found; patch NOT reset")
        return
    import serial
    s = serial.Serial(port, 115200, timeout=0.2)
    s.setDTR(False)
    s.setRTS(True)
    time.sleep(0.15)
    s.setRTS(False)
    s.close()
    time.sleep(2.5)


def load(path):
    w = wave.open(path)
    d = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    w.close()
    return d.reshape(-1, 2).astype(np.float64) / 32768.0


def first_onset(st, thresh=0.01):
    """Capture time of the first audible sample, used to calibrate."""
    loud = np.where(np.abs(st).max(axis=1) > thresh)[0]
    return None if loud.size == 0 else loud[0] / float(RATE)


def window_peak(st, t0, t1):
    a, b = max(int(t0 * RATE), 0), min(int(t1 * RATE), st.shape[0])
    seg = st[a:b]
    return 0.0 if seg.shape[0] == 0 else float(np.abs(seg).max())


def max_step(st, t0, t1):
    a, b = max(int(t0 * RATE), 0), min(int(t1 * RATE), st.shape[0])
    seg = st[a:b]
    if seg.shape[0] < 4:
        return 0.0, 0.0
    d = np.abs(np.diff(seg, axis=0))
    i = int(np.argmax(d.max(axis=1)))
    return float(d.max()), (a + i) / float(RATE)


def report(st, label, t_first_on, t_steal):
    peak = float(np.abs(st).max())
    onset = first_onset(st)
    if onset is None or peak < 1e-4:
        print("  FAIL: no signal captured (peak %.1f dBFS)" % db(peak))
        return False

    offset = onset - t_first_on          # wall clock -> capture time
    steal_at = t_steal + offset

    ref_step, _ = max_step(st, steal_at - 0.18, steal_at - 0.02)
    stl_step, stl_at = max_step(st, steal_at - 0.01, steal_at + 0.12)

    # Validity. The whole point is to observe a LOUD voice being truncated, so
    # the voice has to still be loud when the steal lands. Compare the signal
    # present just before the steal with the reference window it is measured
    # against: if the level has collapsed, either the calibration put the
    # window in the wrong place or the tail had already ended, and the step
    # number means nothing. Reporting it anyway is how a measurement tool
    # tells a comfortable lie.
    ref_level = window_peak(st, steal_at - 0.18, steal_at - 0.02)
    stl_level = window_peak(st, steal_at - 0.02, steal_at)

    print("  %s" % label)
    print("    peak level                        %7.1f dBFS" % db(peak))
    print("    steal expected in the capture at  %7.3f s  (calibrated)"
          % steal_at)
    print("    level in the reference window     %7.1f dBFS" % db(ref_level))
    print("    level just before the steal       %7.1f dBFS" % db(stl_level))

    if ref_level < 0.02 or stl_level < 0.25 * ref_level:
        print("    INVALID: the voice was not loud at the steal "
              "(%.1f dB below the reference). Discard this run."
              % (db(ref_level) - db(stl_level)))
        return False

    print("    max step, tail only               %7.1f dBFS  (%.4f FS)"
          % (db(ref_step), ref_step))
    print("    max step, across the steal        %7.1f dBFS  (%.4f FS)"
          % (db(stl_step), stl_step))
    print("    largest step is at                %7.3f s" % stl_at)
    print("    the steal exceeds the waveform by %7.1f dB"
          % (db(stl_step) - db(ref_step)))

    # The headline number. The absolute step scales with how loud the voice
    # happened to be when it was stolen, and that varies by several dB between
    # runs because the tail is still decaying. Dividing by the level just
    # before the steal removes that, so runs are comparable to each other and
    # across builds.
    print("    STEP AS A FRACTION OF THE VOICE   %7.2f %%"
          % (100.0 * stl_step / max(stl_level, 1e-9)))
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", default="build")
    ap.add_argument("--skip-reset", action="store_true")
    ap.add_argument("--attack", type=int, default=0,
                    help="CC 73: 0 = fastest attack, 127 = slowest")
    ap.add_argument("--steal-attack", type=int, default=None,
                    help="CC 73 applied just before the stealing note "
                         "only. A slow value here isolates what the fade "
                         "leaves behind from the new note's own onset, "
                         "without weakening the tail being stolen.")
    a = ap.parse_args()

    if not a.skip_reset:
        print("[reset] rebooting the ESP for a clean default patch")
        reboot_esp()

    subprocess.run(["amixer", "-c", "1", "cset", "numid=16", "2"],
                   capture_output=True)
    subprocess.run(["amixer", "-c", "1", "cset", "numid=13", "on"],
                   capture_output=True)

    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True)
    t_first_on = t_steal = None
    try:
        print("[ble] connecting %s ..." % NOAIDI_MAC)
        bt("connect %s" % NOAIDI_MAC, btctl)
        if not wait_for_alsa_port():
            print("FAIL: BLE ALSA port never appeared")
            return 1
        client, port = open_midi_out()
        from alsa_midi import NoteOnEvent, NoteOffEvent, ControlChangeEvent

        def send(ev):
            client.event_output(ev, port=port)
            client.drain_output()

        for cc, val in SETUP_CCS + [(73, a.attack)]:
            send(ControlChangeEvent(channel=0, param=cc, value=val))
            time.sleep(0.004)
        time.sleep(0.20)

        rec = subprocess.Popen(
            ["arecord", "-D", AUDIO_DEV, "-f", "S16_LE", "-r", str(RATE),
             "-c", "2", "-t", "wav", "-q", "-d", str(CAPTURE_SECS),
             CAPTURE_WAV])
        t_rec = time.time()
        time.sleep(0.40)

        # Fill the pool FIRST. Sending 31 notes over BLE takes 200 ms or
        # more, and an earlier version of this script did it between the loud
        # note's note-off and the steal. That put the steal near the end of
        # the release tail, so promote_idle() sometimes retired and hard-muted
        # the voice before the steal arrived: nothing left to truncate, and a
        # missed experiment that looked like a clean result. Doing it first
        # makes the gap 30 ms and the observation reliable.
        print("[seq] 31 held notes at velocity 1: pool filled, inaudible")
        for n in QUIET_NOTES:
            send(NoteOnEvent(note=n, channel=0, velocity=1))
            time.sleep(0.002)

        # The loud note takes the one remaining voice. It is also the first
        # AUDIBLE event in the capture, which is what the calibration needs.
        time.sleep(0.05)
        print("[seq] one loud note into the last free voice")
        t_first_on = time.time() - t_rec
        send(NoteOnEvent(note=LOUD_NOTE, channel=0, velocity=127))
        time.sleep(0.45)
        send(NoteOffEvent(note=LOUD_NOTE, channel=0))
        print("[seq] released: now the ONLY voice whose gate is low, and loud")

        if a.steal_attack is not None:
            # The tail is already established at full level; the releasing
            # voice does not care about the attack coefficient, so this
            # only slows the onset of the note about to steal it.
            send(ControlChangeEvent(channel=0, param=73,
                                    value=a.steal_attack))
            time.sleep(0.02)

        time.sleep(0.03)
        t_steal = time.time() - t_rec
        print("[seq] the steal: the only candidate is the loud tail")
        send(NoteOnEvent(note=STEAL_NOTE, channel=0, velocity=127))

        time.sleep(0.60)
        send(ControlChangeEvent(channel=0, param=123, value=0))
        time.sleep(0.10)
        send(ControlChangeEvent(channel=0, param=120, value=0))
        rec.wait()
        client.close()
    finally:
        # AGENTS.md #82: always hand the single BLE slot back.
        try:
            bt("disconnect %s" % NOAIDI_MAC, btctl)
            time.sleep(1.5)
            bt("untrust %s" % NOAIDI_MAC, btctl)
            time.sleep(0.5)
            btctl.stdin.close()
        except Exception:
            pass
        btctl.terminate()

    if not os.path.exists(CAPTURE_WAV) or t_steal is None:
        print("FAIL: no capture (S/PDIF lock?)")
        return 1
    ok = report(load(CAPTURE_WAV), a.label, t_first_on, t_steal)
    print("[restore] rebooting the ESP to a clean default patch")
    reboot_esp()
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
