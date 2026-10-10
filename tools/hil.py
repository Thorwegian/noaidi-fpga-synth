#!/usr/bin/env python3
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
"""FPGA-in-the-loop harness: the board as the test instrument.

One command does the whole loop — load SRAM, reboot the ESP, stimulate over
MIDI, capture S/PDIF, assert — so a gateware question gets a silicon-true
answer in minutes instead of a testbench that cannot see the answer at all.

This exists because of a placement-sensitive fault: 2 of 4 nextpnr seeds of
the same RTL glitched audibly, every build passed STA and the headroom gate
comfortably, and no simulation reproduced it. The board found it in an
afternoon.

    ~/.noaidi-blenv/bin/python3 tools/hil.py probe
    ~/.noaidi-blenv/bin/python3 tools/hil.py probe --load rtl/pack.fs
    ~/.noaidi-blenv/bin/python3 tools/hil.py seeds 2 3 4 5
    ~/.noaidi-blenv/bin/python3 tools/hil.py selftest ref_clean.wav ref_bad.wav

THREE RULES THIS ENCODES, each learned the hard way:

1. RELOADING THE FPGA INVALIDATES THE ESP'S SHADOW IMAGE.
   engine_link keeps `s_param_image` as a copy of the FPGA's state and elides any
   write whose value already matches it. A fresh bitstream resets the FPGA
   without the ESP knowing, so every matching write is then silently skipped.
   Nothing in firmware enforces the reboot, so this harness does — and it
   CHECKS the boot banner rather than trusting the reset, because an esptool
   reset over the C3's USB-JTAG can leave the old app running.

2. VALIDATE THE METRIC BEFORE TRUSTING IT.
   A metric can report faults on provably clean audio, and can print the worst
   build in a set as clean if the fault's frequency band is hard-coded into
   it. `selftest` runs the metric against a known-good and
   a known-bad capture and refuses to proceed if it cannot separate them.

3. NEVER PANIC BETWEEN NOTES IN A REPRODUCTION.
   CC120 between notes suppresses the fault entirely. The probe plays
   the way a person plays: repeated notes, note-offs, default release, no panic.
   It also always sends CC123+CC120 BEFORE dropping BLE, because a note-off
   that races the disconnect strands a voice sounding forever.
"""
import argparse
import subprocess
import sys
import time
import wave

import numpy as np

RATE = 48000
AUDIO_DEV = "hw:1,0"
ESP_PORT = "/dev/ttyACM0"
RTL_DIR = "rtl"

# Reference signature, measured on captures confirmed by ear:
#   clean    min/mean ~0.40-0.62, nothing above 8.5 Hz in the envelope
#   faulty   min/mean <0.09, envelope modulation 15-49% deep at 31-58 Hz
# min/mean and depth are the discriminators. The RATE IS NOT: the two faulty
# placements modulated at 55 Hz and 31 Hz, and gating on a band hid one of them.
FAULT_MINMEAN = 0.15
FAULT_DEPTH = 0.15

# A working build plays a held note at roughly -24 dBFS with the default patch.
# Checked because the fault metric above measures MODULATION and will happily
# call a silent or 28 dB-quiet synth "clean" -- which it did, on a build whose
# gateware expected the linear coefficient format while the ESP was sending
# nibble rates. Level is a different failure from modulation and needs
# its own assertion.
LEVEL_NOMINAL_DB = -24.0
LEVEL_TOLERANCE_DB = 8.0


# ---------------------------------------------------------------- board

def load_sram(bitstream):
    """Upload a bitstream to SRAM (volatile; does not touch flash)."""
    r = subprocess.run(["openFPGALoader", "-b", "tangnano20k", "-m", bitstream],
                       capture_output=True, text=True, timeout=300)
    ok = r.returncode == 0
    print(f"[sram] {bitstream}: {'loaded' if ok else 'FAILED'}")
    if not ok:
        print("       " + (r.stderr or r.stdout)[-300:])
    return ok


def reboot_esp(timeout_s=6.0):
    """Reset the C3 and PROVE it rebooted. See rule 1 in the module docstring."""
    try:
        import serial
    except ImportError:
        print("[esp] pyserial missing; cannot reboot or verify")
        return False
    try:
        s = serial.Serial(ESP_PORT, 115200, timeout=0.3)
    except Exception as e:
        print(f"[esp] cannot open {ESP_PORT}: {e}")
        return False
    try:
        s.dtr = False
        s.rts = True
        time.sleep(0.15)
        s.rts = False
        time.sleep(0.05)
        s.dtr = True
        t0 = time.time()
        while time.time() - t0 < timeout_s:
            ln = s.readline().decode("utf-8", "replace").strip()
            if ln and any(k in ln for k in ("ESP-ROM", "cpu_start", "boot:")):
                print(f"[esp] rebooted: {ln[:70]}")
                return True
        print("[esp] NO BOOT BANNER — the old app may still be running, which "
              "means the shadow image is stale and results are suspect")
        return False
    finally:
        s.close()


def capture(secs, path="/tmp/hil_cap.wav"):
    """Capture S/PDIF. Returns (left, right) as float arrays in [-1, 1).

    arecord refuses a non-integer -d, and silently captures NOTHING if given
    one — which once stranded a voice because the exception skipped a note-off.
    """
    subprocess.run(["arecord", "-D", AUDIO_DEV, "-f", "S16_LE", "-r", str(RATE),
                    "-c", "2", "-t", "wav", "-q", "-d", str(int(secs)), path],
                   capture_output=True)
    w = wave.open(path)
    d = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    w.close()
    st = d.reshape(-1, 2).astype(np.float64) / 32768.0
    return st[:, 0], st[:, 1]


# ---------------------------------------------------------------- measurement

def signature(x, hop=96):
    """Envelope signature: (min/mean, depth, rate_hz, rms_db) or None if silent.

    hop=96 is 2 ms, so the envelope Nyquist is 250 Hz — comfortably above any
    modulation this hunts for (31-58 Hz).
    """
    n = (len(x) // hop) * hop
    if n == 0:
        return None
    e = np.sqrt((x[:n].reshape(-1, hop) ** 2).mean(axis=1))
    dc = e.mean()
    if dc < 1e-6:
        return None
    a = e - dc
    sp = np.abs(np.fft.rfft(a * np.hanning(len(a)))) / (len(a) / 4)
    fr = np.fft.rfftfreq(len(a), hop / RATE)
    band = (fr >= 20) & (fr <= 200)
    i = int(np.argmax(sp[band]))
    rms = np.sqrt((x ** 2).mean())
    return (e.min() / dc, sp[band][i] / dc, fr[band][i],
            20 * np.log10(max(rms, 1e-12)))


def is_faulty(sig):
    return sig is not None and sig[0] <= FAULT_MINMEAN and sig[1] >= FAULT_DEPTH


def level_ok(sig):
    """Is the level anywhere near what a working build produces?"""
    return sig is not None and abs(sig[3] - LEVEL_NOMINAL_DB) <= LEVEL_TOLERANCE_DB


def fmt(sig):
    if sig is None:
        return "silent"
    mm, depth, hz, rms = sig
    verdict = "FAULT" if is_faulty(sig) else "clean"
    if not level_ok(sig):
        verdict += (f"  ** LEVEL {rms:+.1f} dB, expected "
                    f"{LEVEL_NOMINAL_DB:+.0f} +/-{LEVEL_TOLERANCE_DB:.0f} -- "
                    f"is the firmware's wire format matched to the gateware? **")
    return (f"min/mean {mm:5.3f}  depth {100*depth:5.1f}%  at {hz:6.2f} Hz  "
            f"rms {rms:+6.1f} dB  {verdict}")


# ---------------------------------------------------------------- stimulus

class Synth:
    """BLE MIDI to the synth, with a teardown that cannot strand a voice."""

    def __init__(self):
        sys.path.insert(0, __file__.rsplit("/", 1)[0])
        from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC
        self._bt, self._wait = bt, wait_for_alsa_port
        self._open, self._mac = open_midi_out, NOAIDI_MAC
        self.client = None

    def __enter__(self):
        self.btctl = subprocess.Popen(
            ["bluetoothctl"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, text=True)
        self._bt(f"connect {self._mac}", self.btctl)
        if not self._wait():
            raise RuntimeError("BLE MIDI port never appeared")
        self.client, self.port = self._open()
        from alsa_midi import NoteOnEvent, NoteOffEvent, ControlChangeEvent
        self._On, self._Off, self._CC = NoteOnEvent, NoteOffEvent, ControlChangeEvent
        self.panic()
        return self

    def _send(self, ev):
        self.client.event_output(ev, port=self.port)
        self.client.drain_output()

    def cc(self, num, val):
        self._send(self._CC(channel=0, param=num, value=val))
        time.sleep(0.05)

    def on(self, note, vel=100):
        self._send(self._On(note=note, channel=0, velocity=vel))

    def off(self, note):
        self._send(self._Off(note=note, channel=0, velocity=0))

    def panic(self):
        self.cc(123, 0)
        self.cc(120, 0)

    def __exit__(self, *exc):
        # rule 3: silence BEFORE the link drops, always, even on an exception
        try:
            self.panic()
            time.sleep(0.3)
            if self.client is not None:
                self.client.close()
        except Exception:
            pass
        for cmd in ("disconnect", "untrust"):
            try:
                self._bt(f"{cmd} {self._mac}", self.btctl)
                time.sleep(1.0)
            except Exception:
                pass
        try:
            self.btctl.stdin.close()
        except Exception:
            pass
        self.btctl.terminate()
        for cmd in ("disconnect", "untrust"):
            subprocess.run(["bluetoothctl", cmd, self._mac],
                           capture_output=True, timeout=10)
        return False


# ---------------------------------------------------------------- tests

def probe(rounds=6, note=84, secs=5):
    """The reproduction: repeated notes, no panic between them."""
    with Synth() as s:
        time.sleep(2.0)
        print("  control: one note, nothing played before it")
        time.sleep(10.0)
        s.on(note); time.sleep(0.15)
        l, _ = capture(secs); s.off(note)
        ctl = signature(l)
        print(f"    {fmt(ctl)}")

        worst = ctl
        for rnd in range(rounds):
            for _ in range(8):
                s.on(note); time.sleep(0.5); s.off(note); time.sleep(0.18)
            s.on(note); time.sleep(0.15)
            l, _ = capture(secs); s.off(note)
            sig = signature(l)
            print(f"    round {rnd}, {8*(rnd+1)} notes: {fmt(sig)}")
            if sig and (worst is None or sig[0] < worst[0]):
                worst = sig
            if is_faulty(sig):
                print("  VERDICT: FAULT reproduced")
                return 1
            if not level_ok(sig):
                print("  VERDICT: level wrong -- not a modulation fault, but "
                      "this build is not working correctly")
                return 1
    print("  VERDICT: clean")
    return 0


def selftest(clean_wav, bad_wav):
    """Rule 2: the metric must separate a known-good capture from a known-bad
    one before any of its numbers mean anything."""
    ok = True
    for path, want_fault in ((clean_wav, False), (bad_wav, True)):
        w = wave.open(path)
        ch = w.getnchannels()
        d = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
        w.close()
        x = (d.reshape(-1, 2)[:, 0] if ch == 2 else d).astype(np.float64) / 32768.0
        sig = signature(x)
        got = is_faulty(sig)
        print(f"  {path}: {fmt(sig)}   expected "
              f"{'FAULT' if want_fault else 'clean'}   "
              f"{'OK' if got == want_fault else 'MISMATCH'}")
        ok &= (got == want_fault)
    print("  metric is trustworthy" if ok else
          "  METRIC FAILED ITS OWN SELFTEST — do not believe its numbers")
    return 0 if ok else 1


def seeds(seed_list, note=84):
    """Build each placement seed and test it on the hardware: 2 of 4 seeds
    of identical RTL have been audibly broken."""
    rc = 0
    for sd in seed_list:
        print(f"######## seed {sd} ########")
        subprocess.run(f"cd {RTL_DIR} && rm -f pnr.json pack.fs && "
                       f"make SEED={sd} pack.fs", shell=True,
                       capture_output=True, timeout=2400)
        bs = f"{RTL_DIR}/pack.fs"
        if not load_sram(bs):
            rc = 1
            continue
        reboot_esp()
        time.sleep(2.0)
        rc |= probe(rounds=3, note=note)
    return rc


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", choices=["probe", "selftest", "seeds"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--load", metavar="BITSTREAM",
                    help="load this bitstream to SRAM first (and reboot the ESP)")
    a = ap.parse_args()

    if a.load:
        if not load_sram(a.load):
            return 2
        reboot_esp()
        time.sleep(2.0)

    if a.cmd == "probe":
        return probe()
    if a.cmd == "selftest":
        if len(a.args) != 2:
            print("selftest needs a known-CLEAN wav and a known-BAD wav")
            return 2
        return selftest(a.args[0], a.args[1])
    if a.cmd == "seeds":
        return seeds([int(x) for x in a.args] or [2, 3, 4, 5])
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
