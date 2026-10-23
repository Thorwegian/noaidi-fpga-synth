#!/usr/bin/env python3
"""Randomised note + controller soak over USB MIDI, to surface the CSP drift.

    Copyright © 2026 Thor H. Linløkken <thj@thj.no>
    License: CERN-OHL-S v2

Plays what a player does at the keys while turning knobs: random chords and
single notes with random velocity and hold, knob-like controller walks, and
every few seconds a dense sweep burst the way an Open Stage Control throw
lands (~150 CCs). Every inter-message delay is jittered -- real MIDI is never
precise, and a fixed-timing bench hides timing-dependent faults (#237).

The controllers are weighted onto the ones whose writes land in the CSP's
indexed LFO / channel records (cutoff, resonance, the LFO CCs), which is where
the silent drift lives (#244).

The wire is the one tools/lab/baseline_recording.py uses: `aseqsend` into the
CH345 USB-MIDI adapter (ALSA 16:0) and on into the synth's DIN jack, with
Active Sensing every quarter second as a keyboard sends it, so the firmware's
parser never sees the line as silent. BLE is left alone (it is Open Stage
Control's).

    midi_soak.py [seconds] [--seed N] [--rate MSG_PER_S] [--port 16:0] [--program N]

Ends with CC 123 + CC 120 (all notes off). The controllers it walks cannot
be read back, so the only true restore is a Program Change that reloads the
patch from its file: give --program N and it is sent before the soak (a clean
slate) and again after it, as tools/lab/baseline_recording.py does, so no
scrambled controller is left behind. NEVER run this while anyone is playing
the synth -- it plays over them and moves their knobs (2026-10-23, #244).

Read `csp-verify` / `csp-voices` on the console while it runs to catch the
first register that drifts.
"""
import argparse
import random
import subprocess
import threading
import time

# --- the controllers, as voice_alloc.cpp's handle_cc() reads them -------------
CC_CUTOFF     = 74
CC_RESONANCE  = 71
CC_MODWHEEL   = 1
CC_VOLUME     = 7
CC_VEL_AMP    = 86
CC_VEL_MOD    = 87
CC_LFO        = (76, 77, 109, 110, 111, 112, 113, 114, 115, 116)
CC_ALL_OFF    = 123
CC_ALL_SOUND  = 120

# weighted: the indexed-record writers dominate, a little realism on the rest
CC_WEIGHTED = ([CC_CUTOFF] * 6 + [CC_RESONANCE] * 2 + list(CC_LFO) * 2
               + [CC_MODWHEEL, CC_VOLUME, CC_VEL_AMP, CC_VEL_MOD])

NOTE_LOW, NOTE_HIGH = 36, 84          # C2 .. C6


def jitter(mean_s, spread=0.6):
    """A human/OSC-like delay: mean_s scaled by a random factor in [1-spread, 1+spread]."""
    return max(0.0, mean_s * random.uniform(1.0 - spread, 1.0 + spread))


class Wire:
    """The USB MIDI path: hex messages through aseqsend into one ALSA port."""

    def __init__(self, port):
        self.port = port
        self.sent = 0

    def send(self, *messages):
        """One aseqsend call carrying every message given, as a raw byte stream."""
        if not messages:
            return
        subprocess.run(["aseqsend", "-p", self.port, " ".join(messages)], check=True)
        self.sent += len(messages)

    def keepalive(self, stop, period=0.25):
        """Active Sensing, as a keyboard sends it (tools/lab/baseline_recording.py)."""
        while not stop.is_set():
            subprocess.run(["aseqsend", "-p", self.port, "FE"])
            stop.wait(period)


def note_on(note, velocity):  return "90 %02X %02X" % (note, velocity)
def note_off(note):           return "80 %02X 00" % note
def control(cc, value):       return "B0 %02X %02X" % (cc, value)
def program_change(program):  return "C0 %02X" % program


class Soak:
    def __init__(self, wire, rate):
        self.wire = wire
        self.mean_gap = 1.0 / rate            # mean inter-message delay
        self.held = {}                        # note -> release time
        self.knob = {cc: random.randint(0, 127) for cc in set(CC_WEIGHTED)}
        self.notes = self.ccs = 0

    # -- notes ---------------------------------------------------------------
    def strike(self, now):
        """A chord of 1..4 notes, random velocity, held a random while."""
        ons = []
        for note in random.sample(range(NOTE_LOW, NOTE_HIGH + 1), random.randint(1, 4)):
            if note in self.held:
                continue
            ons.append(note_on(note, random.randint(30, 127)))
            self.held[note] = now + random.uniform(0.08, 2.5)
        self.wire.send(*ons)
        self.notes += len(ons)

    def release_due(self, now):
        due = [n for n, t in self.held.items() if t <= now]
        for note in due:
            del self.held[note]
        self.wire.send(*[note_off(n) for n in due])

    # -- controllers -----------------------------------------------------------
    def turn(self, cc, step_max=6):
        """One knob tick: walk the value smoothly, as a hand or an OSC fader does."""
        value = min(127, max(0, self.knob[cc] + random.randint(-step_max, step_max)))
        self.knob[cc] = value
        self.wire.send(control(cc, value))
        self.ccs += 1

    def sweep_burst(self, batch=8):
        """An OSC knob throw: ~100..200 CCs on one controller end to end, ~1 kHz, jittered."""
        cc = random.choice([CC_CUTOFF, CC_CUTOFF, CC_RESONANCE] + list(CC_LFO))
        start, end = self.knob[cc], random.choice((0, 127, random.randint(0, 127)))
        count = random.randint(100, 200)
        values = [round(start + (end - start) * (i + 1) / count) for i in range(count)]
        for i in range(0, count, batch):
            self.wire.send(*[control(cc, v) for v in values[i:i + batch]])
            time.sleep(jitter(0.004 * batch))
        self.knob[cc] = values[-1]
        self.ccs += count

    # -- the session -------------------------------------------------------------
    def run(self, seconds):
        t0 = time.time()
        next_burst = t0 + random.uniform(2.0, 6.0)
        while (now := time.time()) - t0 < seconds:
            self.release_due(now)
            roll = random.random()
            if roll < 0.12:
                self.strike(now)
            elif roll < 0.85:
                self.turn(random.choice(CC_WEIGHTED))
            if now >= next_burst:
                self.sweep_burst()
                next_burst = now + random.uniform(2.0, 6.0)
            time.sleep(jitter(self.mean_gap))

    def silence(self):
        offs = [note_off(n) for n in self.held]
        self.held.clear()
        self.wire.send(*offs, control(CC_ALL_OFF, 0), control(CC_ALL_SOUND, 0))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("seconds", nargs="?", type=float, default=300.0)
    ap.add_argument("--seed", type=int, default=None, help="RNG seed (printed; reuse to replay)")
    ap.add_argument("--rate", type=float, default=120.0,
                    help="mean messages/sec between bursts (bursts add ~1 kHz sweeps)")
    ap.add_argument("--port", default="16:0", help="the ALSA sequencer port of the synth")
    ap.add_argument("--program", type=int, default=None,
                    help="Program Change sent before and after the soak, reloading the patch "
                         "so no walked controller is left behind (baseline_recording.py uses 1)")
    args = ap.parse_args()

    seed = args.seed if args.seed is not None else random.randrange(1 << 31)
    random.seed(seed)
    print(f"[soak] seed {seed}  duration {args.seconds:.0f}s  mean rate {args.rate:.0f}/s  port {args.port}",
          flush=True)

    wire = Wire(args.port)
    if args.program is not None:
        wire.send(program_change(args.program))
        time.sleep(2.0)                       # a Program Change reloads the patch; let it settle
    stop = threading.Event()
    threading.Thread(target=wire.keepalive, args=(stop,), daemon=True).start()
    soak = Soak(wire, args.rate)
    try:
        soak.run(args.seconds)
    finally:
        soak.silence()
        if args.program is not None:
            wire.send(program_change(args.program))   # restore: the patch as the file has it
            time.sleep(2.0)
        stop.set()
        print(f"[soak] done: {soak.notes} notes, {soak.ccs} CCs, {wire.sent} messages  (seed {seed})",
              flush=True)


if __name__ == "__main__":
    main()
