#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""The S/PDIF output as a data pipe: capture it on the dev box and say whether
the receiver gives us the board's samples bit for bit (issue #233).

The receiver is a USB sound card (16-bit stereo at 48 kHz, `hw:1,0`), and a
capture through it can be one of three things: every sample exact (the card
slaves to the S/PDIF clock), every sample exact but one dropped or repeated
now and then (the card runs on its USB clock, and the slip rate is the clock
difference), or values off everywhere (a sample-rate converter in the path,
and then this card is an audio input, not a data pipe). The three counts this
prints — bit errors, drops, inserts — tell them apart in one run.

The known stream is the gateware's test tone until the data mode exists: a
1500 Hz sine from the oscillator's quarter-wave table, enabled by MIDI CC 119,
whose samples at 48 kHz repeat every 32 and whose values this script derives
from `scripts/gen_sine_lut.py` and `rtl/dsp/osc_core.sv` with the same
integer arithmetic, through the 48 kHz path's half-band decimator with its
table (`rtl/dsp/halfband_lut.hex`). Which 96 kHz sample is the newest at a
48 kHz tick is either parity, so the tone has two possible phase sets;
whichever matches is reported.

The standing check is the data stream (`rtl/spdif/spdif_stream.sv`, the
memory map's "data stream"): frames of 64 words with a sync word, a
sequence number, 61 payload words from a known LFSR or the sample counter,
and a CRC-32. A frame whose CRC fails is counted and the hunt for the next
sync word starts after its sync word; the sequence numbers say how many
frames went between the ones that arrived. The stream is switched on from
the firmware's console (`csp-stream lfsr`), so this mode takes a capture
made while it was on, or captures with --device alone.

usage: spdif_capture.py tone   [--seconds N] [--device hw:1,0] [--port 16:0]
                               [--wav FILE] [--keep FILE]
       spdif_capture.py stream [--seconds N] [--device hw:1,0] [--probe-counter]
                               [--wav FILE] [--keep FILE]

With --wav the file is analysed instead of captured. --keep saves the capture.
"""
import argparse
import math
import os
import subprocess
import sys
import time
import wave

import numpy as np

SAMPLE_RATE = 48000
TONE_PERIOD = 32                 # samples at 48 kHz: phase step 2^19 of 2^24
TONE_CC = 119
HALFBAND_TAPS = 63               # rtl/dsp/halfband_decimator.sv
LUT_ENTRIES = 256
LUT_PEAK = (1 << 23) - 1


def sine_lut():
    """The quarter-wave table as rtl/dsp/sine_lut.hex holds it (Q0.24 magnitude)."""
    return [round(math.sin(math.pi / 2 * (i + 0.5) / LUT_ENTRIES) * LUT_PEAK) for i in range(LUT_ENTRIES)]


def tone_sample(phase, lut):
    """osc_core's sine for a 24-bit phase, as top.sv puts it on the mix: the
    Q2.16 output's 16 bits with eight zero bits below (`{tone_q216[15:0], 8'b0}`)."""
    quadrant = (phase >> 22) & 3
    quarter_index = (phase >> 14) & 0xFF
    if quadrant & 1:
        quarter_index = 0xFF - quarter_index
    magnitude = lut[quarter_index]
    sine = -magnitude if quadrant & 2 else magnitude      # 24-bit two's complement
    return (sine >> 8) << 8                               # arithmetic: the 16 bits the tone has, then the zeros


def halfband_taps():
    """The decimator's 63 taps as rtl/dsp/halfband_lut.hex holds them, Q1.17 two's complement."""
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "..", "..", "rtl", "dsp", "halfband_lut.hex")) as handle:
        words = [int(line, 16) for line in handle if line.strip()]
    return [word - (1 << 18) if word & (1 << 17) else word for word in words[:HALFBAND_TAPS]]


def tone_sequences():
    """The two candidate 32-sample sequences at 48 kHz.

    The 48 kHz transmitter sends the half-band decimator's output
    (rtl/dsp/halfband_decimator.sv, #308): for each 48 kHz sample the 63 taps
    over the top 18 bits of the 96 kHz samples back from the newest, rounded
    half up to 24 bits and saturated, as the hardware does it; the card keeps
    the top 16. Which 96 kHz sample is the newest at the 48 kHz tick is either
    parity, so both are tried.
    """
    lut = sine_lut()
    taps = halfband_taps()
    step_96k = 1 << 18
    period_96k = 2 * TONE_PERIOD
    samples_96k = [tone_sample((n * step_96k) & 0xFFFFFF, lut) for n in range(period_96k)]
    sequences = {}
    for parity, name in ((0, "even newest"), (1, "odd newest")):
        filtered = []
        for m in range(TONE_PERIOD):
            acc = sum(taps[k] * (samples_96k[(2 * m + parity - k) % period_96k] >> 6) for k in range(HALFBAND_TAPS))
            value = (acc + (1 << 10)) >> 11                          # Q1.35 -> Q0.24; Python's >> floors, as the RTL's >>>
            value = max(-(1 << 23), min((1 << 23) - 1, value))
            filtered.append(value >> 8)                               # the top 16 bits
        sequences[name] = np.array(filtered, dtype=np.int64)
    return sequences


def capture(seconds, device, port, keep):
    """Turn the test tone on, record it, turn it off; return the samples as (frames, 2)."""
    def midi(message):
        subprocess.run(["aseqsend", "-p", port, message], check=True)

    path = keep or os.path.join(os.environ.get("TMPDIR", "/tmp"), "spdif_capture.wav")
    midi("B0 %02X 7F" % TONE_CC)
    time.sleep(0.5)
    # arecord's -d is whole seconds, and 0 records for ever: at least one
    subprocess.run(["arecord", "-q", "-D", device, "-f", "S16_LE", "-r", str(SAMPLE_RATE), "-c", "2",
                    "-d", str(max(1, int(math.ceil(seconds)))), path], check=True)
    midi("B0 %02X 00" % TONE_CC)
    return read_wav(path)


def read_wav(path):
    with wave.open(path, "rb") as handle:
        if handle.getsampwidth() != 2 or handle.getnchannels() != 2:
            sys.exit("expected 16-bit stereo, got %d-byte × %d channels" % (handle.getsampwidth(),
                                                                            handle.getnchannels()))
        frames = handle.readframes(handle.getnframes())
    return np.frombuffer(frames, dtype="<i2").reshape(-1, 2).astype(np.int64)


def align(samples, sequence):
    """Where in the 32-sample sequence the capture starts: the offset that matches the first period best."""
    best = None
    for offset in range(len(sequence)):
        expected = sequence[(offset + np.arange(min(len(samples), 4 * len(sequence)))) % len(sequence)]
        matches = int(np.sum(expected == samples[:len(expected)]))
        if best is None or matches > best[1]:
            best = (offset, matches)
    return best


def walk(samples, sequence, offset, lookahead=8):
    """Follow the capture against the sequence, re-aligning by one sample at each slip.

    A mismatch that the next `lookahead` samples explain as one sample missing
    is a drop; as one sample repeated or added, an insert; neither, a bit error.
    Returns the counts and the positions of the slips.
    """
    period = len(sequence)
    drops, inserts, errors = [], [], 0
    shift = 0
    i = 0
    n = len(samples)
    while i < n:
        if samples[i] == sequence[(offset + i + shift) % period]:
            i += 1
            continue
        stretch = samples[i:i + lookahead]
        if len(stretch) < lookahead:
            errors += int(np.sum(stretch != sequence[(offset + i + shift + np.arange(len(stretch))) % period]))
            break
        as_drop = sequence[(offset + i + shift + 1 + np.arange(lookahead)) % period]
        as_insert = sequence[(offset + i + shift - 1 + np.arange(lookahead)) % period]
        if np.array_equal(stretch, as_drop):
            drops.append(i)
            shift += 1
        elif np.array_equal(stretch, as_insert):
            inserts.append(i)
            shift -= 1
        else:
            errors += 1
            i += 1
    return drops, inserts, errors


def analyse(samples):
    sequences = tone_sequences()
    seconds = len(samples) / SAMPLE_RATE
    print("captured %d frames (%.1f s)" % (len(samples), seconds))
    verdicts = []
    for channel, name in ((0, "left"), (1, "right")):
        column = samples[:, channel]
        scores = {label: align(column, seq) for label, seq in sequences.items()}
        label, (offset, matches) = max(scores.items(), key=lambda item: item[1][1])
        sequence = sequences[label]
        exact = int(np.sum(column == sequence[(offset + np.arange(len(column))) % TONE_PERIOD]))
        drops, inserts, errors = walk(column, sequence, offset)
        print("%s: phase set %s, offset %d; %d of %d samples exact in place (%.4f %%)" % (
            name, label, offset, exact, len(column), 100.0 * exact / len(column)))
        print("  slips: %d drops, %d inserts (%.3f a second); %d samples explained by neither (bit errors)" % (
            len(drops), len(inserts), (len(drops) + len(inserts)) / seconds, errors))
        if drops or inserts:
            positions = sorted(drops + inserts)[:12]
            print("  first slips at samples %s" % ", ".join(str(p) for p in positions))
        verdicts.append((len(drops) + len(inserts), errors))
    identical = int(np.sum(samples[:, 0] == samples[:, 1]))
    print("left equals right on %d of %d frames" % (identical, len(samples)))
    slips = sum(v[0] for v in verdicts)
    errors = sum(v[1] for v in verdicts)
    if errors == 0 and slips == 0:
        print("verdict: bit-perfect, no slips — the card follows the S/PDIF clock")
    elif errors == 0:
        print("verdict: values exact, %d slips — the card runs on its own clock; the slip rate is the drift" % slips)
    else:
        print("verdict: %d samples wrong — something between the board and the file changes values" % errors)


# ---- the data stream ------------------------------------------------------

STREAM_SYNC = 0xB7E15A3C
STREAM_FRAME_WORDS = 64
STREAM_CRC_POLYNOMIAL = 0x04C11DB7
STREAM_LFSR_SEED = 1
STREAM_LFSR_TAPS = 0x00400007
SOURCE_LFSR, SOURCE_COUNTER, SOURCE_PROBE, SOURCE_ENGINE, SOURCE_DUMP = 0, 1, 2, 3, 4


def crc32_words(words):
    """The stream's CRC: IEEE 802.3's polynomial, MSB first, all ones to start, no final inversion."""
    crc = 0xFFFFFFFF
    for word in words:
        for bit in range(31, -1, -1):
            feedback = ((crc >> 31) ^ (word >> bit)) & 1
            crc = (crc << 1) & 0xFFFFFFFF
            if feedback:
                crc ^= STREAM_CRC_POLYNOMIAL
    return crc


def lfsr_32_steps(state):
    for _ in range(32):
        out = state >> 31
        state = (state << 1) & 0xFFFFFFFF
        if out:
            state ^= STREAM_LFSR_TAPS
    return state


def analyse_stream(samples, probe_counter=False):
    """Frames out of the capture: sync, sequence, CRC, and the payload against its source.

    With probe_counter, the probe's register is a counter a program adds one to in every
    pass: the stream carries one word a pass, the even register's on even positions, so the
    even words must step by 2 inside a frame and by 4 across the header, the CRC and the
    sync between frames. Any other step is a pass the chip did not run (or ran twice)."""
    words = ((samples[:, 0].astype(np.int64) & 0xFFFF) << 16) | (samples[:, 1].astype(np.int64) & 0xFFFF)
    words = words.astype(np.uint64).tolist()
    seconds = len(words) / SAMPLE_RATE
    print("captured %d words (%.1f s)" % (len(words), seconds))
    frames_ok = frames_bad_crc = 0
    sequence_gaps = 0
    payload_errors = 0
    counter_slips = 0
    probe_pairs = {}                 # (even, odd) -> how many frames carried it
    registers = {}                   # the dump source: register -> its word, the last seen
    dump_words = 0
    sink_words = {}                  # the engine source: sink word -> samples it was seen in
    mix_left, mix_right = [], []     # and the mix's top 14 bits, a sample each
    expected_sequence = None
    lfsr = None                      # unknown until the first LFSR frame is seen whole
    previous_counter = None
    previous_even = None
    probe_steps = probe_step_errors = 0
    position = 0
    while position + STREAM_FRAME_WORDS <= len(words):
        if words[position] != STREAM_SYNC:
            position += 1
            continue
        frame = [int(w) for w in words[position:position + STREAM_FRAME_WORDS]]
        if crc32_words(frame[:63]) != frame[63]:
            frames_bad_crc += 1
            position += 1            # a false sync, or a slipped frame: hunt on from the next word
            continue
        sequence = frame[1] >> 16
        source = frame[1] & 7
        if expected_sequence is not None and sequence != expected_sequence:
            sequence_gaps += (sequence - expected_sequence) & 0xFFFF
        expected_sequence = (sequence + 1) & 0xFFFF
        payload = frame[2:63]
        if source == SOURCE_LFSR:
            if lfsr is None:
                lfsr = payload[0]    # join the sequence where it stands: the state at position 2
            state = lfsr
            for index, word in enumerate(payload):
                if word != state:
                    payload_errors += 1
                state = lfsr_32_steps(state)
            # positions 0 and 1 of the next frame step the LFSR too, position 63 does not
            lfsr = lfsr_32_steps(lfsr_32_steps(state))
        elif source == SOURCE_COUNTER:
            for index, word in enumerate(payload):
                if previous_counter is not None:
                    step = 4 if index == 0 else 1
                    if word != (previous_counter + step) & 0xFFFFFFFF:
                        counter_slips += 1
                previous_counter = word
            if lfsr is not None:
                for _ in range(63):
                    lfsr = lfsr_32_steps(lfsr)
        elif source == SOURCE_DUMP:
            # the register file: a register a pass, its index in the top 11 bits, its word in the low 18
            for word in payload:
                registers[word >> 21] = word & 0x3FFFF
                dump_words += 1
            if lfsr is not None:
                for _ in range(63):
                    lfsr = lfsr_32_steps(lfsr)
        elif source == SOURCE_ENGINE:
            # the engine's view: the sink word in the top 18 bits, the mix's top 14 bits below
            # (left on even positions, right on odd), a sample each
            for index, word in enumerate(payload):
                sink = word >> 14
                sink_words[sink] = sink_words.get(sink, 0) + 1
                mix = word & 0x3FFF
                mix = mix - 0x4000 if mix & 0x2000 else mix
                (mix_left if index % 2 == 0 else mix_right).append(mix)
            if lfsr is not None:
                for _ in range(63):
                    lfsr = lfsr_32_steps(lfsr)
        else:
            # the probe's pair: the even word on even positions, the odd on odd ones
            pair = (payload[0], payload[1])             # positions 2 and 3
            probe_pairs[pair] = probe_pairs.get(pair, 0) + 1
            if probe_counter:
                for index in range(0, len(payload), 2):
                    word = payload[index] & 0x3FFFF
                    if previous_even is not None:
                        probe_steps += 1
                        if word != (previous_even + (4 if index == 0 else 2)) & 0x3FFFF:
                            probe_step_errors += 1
                    previous_even = word
            if lfsr is not None:
                for _ in range(63):
                    lfsr = lfsr_32_steps(lfsr)
        frames_ok += 1
        position += STREAM_FRAME_WORDS
    print("frames: %d whole, %d with a failed CRC (a slip or a false sync); %d frames missing by the sequence numbers" % (
        frames_ok, frames_bad_crc, sequence_gaps))
    print("payload: %d LFSR words wrong, %d counter steps wrong" % (payload_errors, counter_slips))
    if probe_counter:
        print("probe counter: %d steps checked, %d not 2 (or 4 across a frame): %d passes lost or repeated at most" % (
            probe_steps, probe_step_errors, probe_step_errors))
        counter_slips += probe_step_errors
    else:
        for (even, odd), count in sorted(probe_pairs.items(), key=lambda item: -item[1])[:8]:
            print("probe pair: even %05x odd %05x in %d frames" % (even, odd, count))
    if dump_words:
        print("dump: %d registers of 2048 seen in %d words (%.1f times each)" % (
            len(registers), dump_words, dump_words / max(len(registers), 1)))
    if sink_words:
        def signed18(raw):
            return raw - 0x40000 if raw & 0x20000 else raw
        print("sink word at the probe's address: %d distinct values over %d samples; the commonest:" % (
            len(sink_words), sum(sink_words.values())))
        for raw, count in sorted(sink_words.items(), key=lambda item: -item[1])[:6]:
            print("  %05x (%d, %.4f) in %d samples" % (raw, signed18(raw), signed18(raw) / 16384.0, count))
        for name, mix in (("left", mix_left), ("right", mix_right)):
            if not mix:
                continue
            values = np.array(mix, dtype=np.float64) / 8192.0          # 14 bits: full scale is 8192
            peak = np.max(np.abs(values))
            rms = np.sqrt(np.mean(values * values))
            print("mix %s: peak %s, rms %s, %d of %d samples nonzero" % (
                name, "%.1f dBFS" % (20 * np.log10(peak)) if peak > 0 else "silence",
                "%.1f dBFS" % (20 * np.log10(rms)) if rms > 0 else "silence",
                int(np.count_nonzero(values)), len(values)))
    rate = 32 * SAMPLE_RATE / 1e6
    print("the pipe: %.3f Mbit/s, %d bits a sample" % (rate, 32))
    if frames_ok and not frames_bad_crc and not sequence_gaps and not payload_errors and not counter_slips:
        print("verdict: bit-perfect, every frame whole")
    elif frames_ok:
        print("verdict: frames arrive, with the losses above")
    else:
        print("verdict: no whole frame — is the stream on (csp-stream lfsr)?")
    return registers


def write_dump(registers, path, before=""):
    """The registers as csp-peek prints them (a pair a line), for `csp match -c`; the first line
    carries the pass counter's register before the run, as chip_check.py writes it."""
    with open(path, "w") as out:
        out.write("# before the run: %s\n" % before)
        for even in range(0, 2048, 2):
            if even not in registers and even + 1 not in registers:
                continue
            fields = []
            for address in (even, even + 1):
                if address in registers:
                    raw = registers[address]
                    fields.append("%03x: %05x (%d)" % (address, raw, raw - 0x40000 if raw & 0x20000 else raw))
            out.write("  " + "   ".join(fields) + "\n")


def capture_stream(seconds, device, keep):
    path = keep or os.path.join(os.environ.get("TMPDIR", "/tmp"), "spdif_capture.wav")
    # arecord's -d is whole seconds, and 0 records for ever: at least one
    subprocess.run(["arecord", "-q", "-D", device, "-f", "S16_LE", "-r", str(SAMPLE_RATE), "-c", "2",
                    "-d", str(max(1, int(math.ceil(seconds)))), path], check=True)
    return read_wav(path)


def main():
    parser = argparse.ArgumentParser(description="the S/PDIF output as a data pipe")
    parser.add_argument("mode", choices=["tone", "stream"], help="the known stream to check against")
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--device", default="hw:1,0", help="the ALSA capture device of the S/PDIF input")
    parser.add_argument("--port", default="16:0", help="the ALSA sequencer port of the synth (CC 119 = the tone)")
    parser.add_argument("--wav", help="analyse this file instead of capturing")
    parser.add_argument("--keep", help="save the capture here")
    parser.add_argument("--probe-counter", action="store_true",
                        help="stream mode: the probed register counts the passes, check its steps")
    parser.add_argument("--dump", help="stream mode, the dump source: write the register file here, as csp-peek prints it")
    args = parser.parse_args()
    if args.mode == "tone":
        samples = read_wav(args.wav) if args.wav else capture(args.seconds, args.device, args.port, args.keep)
        analyse(samples)
    else:
        samples = read_wav(args.wav) if args.wav else capture_stream(args.seconds, args.device, args.keep)
        registers = analyse_stream(samples, args.probe_counter)
        if args.dump:
            write_dump(registers, args.dump)
            print("%d registers written to %s" % (len(registers), args.dump))


if __name__ == "__main__":
    main()
