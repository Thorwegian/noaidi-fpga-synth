#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""The three acceptances of a bitstream on the board, as one run (#238):

  1. the boot's self-test: the chip does what the model says;
  2. `csp verify`: every register the firmware wrote, read back through the
     probe, none differing;
  3. each baseline (baselines.py: sawbass, then galaxy): its preset loaded,
     its sequence recorded over S/PDIF, through baseline_check.py (Essentia)
     and benchmark_compare.py against its benchmark (tools/lab/benchmark):
     envelope, pitch classes, centroid, partials, valley floor.

A baseline's preset is loaded as a player's controller loads one: Bank Select
and a Program Change over the wire, to the Tests bank. The sequence is
recorded only when the console shows that the preset loaded: the firmware's
line for that Program Change, naming the bank, the program and the file, and
`preset` giving that file as the active one, its every table and key as the
checkout's app/storage has them. A preset that did not load, or a board whose
file is not the checkout's, fails
the run, and its sequence is not played. The first baseline loads onto a synth
just booted, the next onto one that has just played another preset. The
board's storage has to hold the Tests folder and its bank (tools/lab/README.md).

While a sequence records, DIAG_LIMITER (docs/memory_map.md, 0x00A: the
master limiter's applied gain, linear, UQ0.18) is polled over the
console about four times a second, so the take says how much the limiter
worked during the triad (#355): the maximum and the mean over the triad's
window and the take's maximum with its time, the series as
<label>.<baseline>.limiter.csv. It is a reading, not a check: a borderline triad level
has its explanation in the same output.

usage: acceptance.py --out DIR [--label NAME] [--baseline NAME[,NAME...]]
                     [--fs BITSTREAM] [--loader PATH]
                     [--console /dev/ttyACM0] [--port 16:0] [--device hw:1,0]
                     [--boot-seconds 16] [--tail 24] [--no-mp3]

With --fs the bitstream is loaded first (openFPGALoader, SRAM). The ESP32 is
reset through the console's RTS and its boot log read; then, for each baseline,
the preset is loaded, the sequence recorded (baseline_recording.py), checked and compared,
and the recording encoded as MP3 at 320 kbps (libmp3lame) for review. DIR gets
the boot log and verdict.json, and for each baseline, as <label>.<baseline>.*, the
recording, the tables, the plot and the limiter series; the exit
status is 0 when all three pass. The channel's bank is put back to 0 at the
end. Run it with the interpreter Essentia is installed in.
"""
import argparse
import json
import math
import os
import re
import subprocess
import sys
import threading
import time

import serial

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from baselines import BASELINES, TESTS_BANK, bank_select  # noqa: E402
from chip_check import ANSI, command  # noqa: E402

SELF_TEST_PASS = "self-test: the chip does what the model says"
SELF_TEST_FAIL = "THE CHIP DOES NOT DO WHAT THE MODEL SAYS"
BOOT_IMAGE = re.compile(r"boot image: ([^\r\n]{0,100})")
PROGRAM = re.compile(r"control program loaded: ([^\r\n]{0,100})")
VERIFIED = re.compile(r"verified: (\d+) register")
DIAG = re.compile(r"passes (\d+)\s+queue \S+\s+limiter (\S+)\s+dropped (\d+)")
# the firmware's line for a Program Change, loaded or not (voice_alloc.cpp)
PROGRAM_CHANGE = re.compile(r"bank (\d+) program (\d+): ([^\r\n]{0,200})")
LOAD_SECONDS = 3.0                                # how long the console is read for that line
# a table or a key of a preset file (docs/storage_format.md)
PRESET_LINE = re.compile(r"^(\[\[?[a-z_0-9]+\]\]?|[a-z_0-9]+ = \S.*)$")
STORAGE = os.path.join(HERE, "..", "..", "app", "storage")
LIMITER_UNITY = 1 << 18                           # DIAG_LIMITER[18:0]: the applied gain, UQ0.18 (master_limiter.sv)
LIMITER_FLOOR_DB = 110.0                          # a gain of zero, which the chip never publishes
LIMITER_POLL_S = 0.2                              # the console's wait per csp diag; about four readings a second
# The triad in the take's clock: baseline_recording.py starts its recorder
# about half a second after it is launched (imports, the first Active
# Sensing and its settle), then a beat of lead-in and fifteen beats of scale,
# held C6 and silence before the triad's four beats (its segments()). The
# window keeps half a second clear of both ends of the triad.
TRIAD_WINDOW_S = (17.0, 20.0)


def limiter_db(word):
    """DIAG_LIMITER's word as the limiter's reduction in dB: 20 log10(unity / gain)."""
    gain = int(word, 16) & 0x7FFFF
    if gain >= LIMITER_UNITY:
        return 0.0
    if gain == 0:
        return LIMITER_FLOOR_DB
    return 20.0 * math.log10(LIMITER_UNITY / float(gain))


def poll_limiter(port, readings, stop, t0):
    """DIAG_LIMITER read until stop is set: (seconds since t0, reduction dB) appended to readings."""
    while not stop.is_set():
        match = DIAG.search(command(port, "csp diag", LIMITER_POLL_S))
        if match:
            readings.append((time.monotonic() - t0, limiter_db(match.group(2))))


def limiter_summary(readings):
    """The triad window's maximum and mean, the take's maximum and its time."""
    if not readings:
        return None
    window = [db for t, db in readings if TRIAD_WINDOW_S[0] <= t <= TRIAD_WINDOW_S[1]]
    at, take_max = max(readings, key=lambda r: r[1])
    return {"readings": len(readings), "window_s": list(TRIAD_WINDOW_S),
            "triad_max_db": round(max(window), 2) if window else None,
            "triad_mean_db": round(sum(window) / len(window), 2) if window else None,
            "take_max_db": round(take_max, 2), "take_max_at_s": round(at, 1)}


def listen(port, seconds):
    """What the console prints in this many seconds, ANSI stripped."""
    end = time.time() + seconds
    chunks = []
    while time.time() < end:
        data = port.read(4096)
        if data:
            chunks.append(data.decode("utf-8", "replace"))
    return ANSI.sub("", "".join(chunks))


def boot(port, seconds):
    """Reset the ESP32 and return its boot log, ANSI stripped."""
    port.reset_input_buffer()
    port.dtr = False
    port.rts = True
    time.sleep(0.2)
    port.rts = False
    return listen(port, seconds)


def send(midi_port, *messages):
    """MIDI over the wire, as aseqsend's hex. The sequencer port is held open
    by a subscription of Midi Through for the call: the kernel drops a direct
    event to a port nobody subscribes to, without an error."""
    subprocess.run(["aconnect", "14:0", midi_port], capture_output=True)
    try:
        for message in messages:
            subprocess.run(["aseqsend", "-p", midi_port, message], check=True)
        time.sleep(0.2)                           # the bytes leave the adapter before the port closes
    finally:
        subprocess.run(["aconnect", "-d", "14:0", midi_port], capture_output=True)


def preset_lines(text):
    """A preset's tables and keys as the firmware writes them: the lines of a
    preset file, or of the console's `preset`, that are a table or a key."""
    return [line.strip() for line in text.splitlines() if PRESET_LINE.match(line.strip())]


def load_baseline(port, midi_port, baseline):
    """The baseline's preset by Bank Select and Program Change, and what the
    console shows of it: (loaded, what was seen). It is loaded when the
    firmware's line for the change names the bank, the program and the file,
    and `preset` gives that file as the active one with every table and key as
    the checkout's file has them."""
    port.reset_input_buffer()
    send(midi_port, *bank_select(TESTS_BANK), "C0 %02X" % baseline.program)
    lines = [m.group(0).strip() for m in PROGRAM_CHANGE.finditer(listen(port, LOAD_SECONDS))]
    wanted = "bank %d program %d: %s" % (TESTS_BANK, baseline.program, baseline.preset)
    if wanted not in lines:
        return False, "; ".join(lines) if lines else "no line for a Program Change on the console"
    active = command(port, "preset", 3.0)
    if ("# /" + baseline.preset) not in active:
        return False, "%s, but `preset` does not give /%s as the active preset" % (wanted, baseline.preset)
    with open(os.path.join(STORAGE, baseline.preset)) as source:
        file_lines = preset_lines(source.read())
    board_lines = preset_lines(active)
    if board_lines != file_lines:
        differing = [(a, b) for a, b in zip(board_lines, file_lines) if a != b]
        detail = ("the board has `%s` where the file has `%s`" % differing[0] if differing
                  else "the board gives %d tables and keys, the file has %d" % (len(board_lines), len(file_lines)))
        return False, "%s, but the active preset is not app/storage/%s: %s" % (wanted, baseline.preset, detail)
    return True, "%s; `preset` gives the file's %d tables and keys" % (wanted, len(file_lines))


def run(args_list, log):
    """A tool's output, printed and kept."""
    result = subprocess.run(args_list, capture_output=True, text=True)
    text = result.stdout + result.stderr
    lines = [line for line in text.splitlines() if not line.startswith("[") and line.strip()]
    log.extend(lines)
    print("\n".join(lines))
    return result.returncode


def main():
    parser = argparse.ArgumentParser(description="the three acceptances on the board")
    parser.add_argument("--out", required=True, help="the directory for the recordings, the tables and the verdict")
    parser.add_argument("--label", default="take", help="the files' base name")
    parser.add_argument("--baseline", default="sawbass,galaxy",
                        help="the baselines to play, comma-separated, in order (baselines.py)")
    parser.add_argument("--fs", help="load this bitstream first (SRAM)")
    parser.add_argument("--loader", default="openFPGALoader", help="--fs: the loader")
    parser.add_argument("--console", default="/dev/ttyACM0", help="the firmware's serial console")
    parser.add_argument("--port", default="16:0", help="the ALSA sequencer port of the synth")
    parser.add_argument("--device", default="hw:1,0", help="the ALSA capture device of the S/PDIF input")
    parser.add_argument("--boot-seconds", type=float, default=16.0, help="how long the boot log is read")
    parser.add_argument("--tail", type=float, default=24.0, help="seconds recorded after the triad's release")
    parser.add_argument("--no-mp3", action="store_true", help="no MP3 for review")
    args = parser.parse_args()
    names = args.baseline.split(",")
    unknown = [name for name in names if name not in BASELINES]
    if unknown:
        parser.error("no baseline %s; baselines.py has %s" % (", ".join(unknown), ", ".join(sorted(BASELINES))))

    os.makedirs(args.out, exist_ok=True)
    base = os.path.join(args.out, args.label)
    verdict = {"label": args.label, "bitstream": args.fs, "when": time.strftime("%Y-%m-%dT%H:%M:%S")}

    if args.fs:
        print("== bitstream %s" % args.fs)
        loaded = subprocess.run([args.loader, "-b", "tangnano20k", "-m", args.fs], capture_output=True, text=True)
        verdict["bitstream_loaded"] = loaded.returncode == 0
        if loaded.returncode != 0:
            print(loaded.stdout + loaded.stderr)
            print("the bitstream did not load")
        time.sleep(1.0)

    port = serial.Serial(args.console, 115200, timeout=0.1)

    # 1. the boot and its self-test
    print("== boot")
    boot_log = boot(port, args.boot_seconds)
    with open(base + ".boot.txt", "w") as out:
        out.write(boot_log)
    self_test_passed = SELF_TEST_PASS in boot_log and SELF_TEST_FAIL not in boot_log
    image_line = BOOT_IMAGE.search(boot_log)
    program_line = PROGRAM.search(boot_log)
    verdict["self_test"] = {"passed": self_test_passed,
                            "lines": [line.strip() for line in boot_log.splitlines() if "self-test" in line]}
    verdict["boot_image"] = image_line.group(1).strip() if image_line else None
    verdict["control_program"] = program_line.group(1).strip() if program_line else None
    print("self-test: %s" % ("passed" if self_test_passed else "FAILED or not seen"))
    print("boot image: %s" % verdict["boot_image"])
    print("control program: %s" % verdict["control_program"])

    # 2. csp verify, while the synth is silent
    print("== csp verify")
    verify = command(port, "csp verify", 4.0)
    match = VERIFIED.search(verify)
    differing = int(match.group(1)) if match else None
    verdict["verify"] = {"differing": differing,
                         "lines": [line.strip() for line in verify.splitlines() if "image" in line][:24]}
    print("verified: %s register(s) differ" % ("?" if differing is None else differing))

    # 3. each baseline: its preset, its sequence, the checks
    verdict["baselines"] = {}
    for name in names:
        baseline = BASELINES[name]
        take = "%s.%s" % (base, name)
        result = verdict["baselines"][name] = {"preset": baseline.preset}
        log = []
        print("== %s: preset" % name)
        loaded, seen = load_baseline(port, args.port, baseline)
        result["preset_loaded"], result["load"] = loaded, seen
        print(seen if loaded else "NOT LOADED: " + seen)
        if not loaded:
            result["audio"] = {"passed": False}
            continue
        time.sleep(1.0)
        diag = DIAG.search(command(port, "csp diag", 2.0))
        result["diag"] = {"passes": int(diag.group(1)), "limiter": diag.group(2), "dropped": int(diag.group(3))} if diag else None

        wav = take + ".wav"
        print("== %s: recording" % name)
        readings, stop = [], threading.Event()
        poller = threading.Thread(target=poll_limiter, args=(port, readings, stop, time.monotonic()), daemon=True)
        poller.start()
        run([sys.executable, os.path.join(HERE, "baseline_recording.py"), wav, "--program", "-1",
             "--transpose", str(baseline.transpose), "--tail", str(args.tail), "--port", args.port,
             "--device", args.device], log)
        stop.set()
        poller.join()
        with open(take + ".limiter.csv", "w") as out:
            out.write("time_s,reduction_db\n")
            for t, db in readings:
                out.write("%.2f,%.3f\n" % (t, db))
        result["limiter"] = limiter_summary(readings)
        if result["limiter"] and result["limiter"]["triad_max_db"] is not None:
            line = "limiter during the triad (%.0f to %.0f s of the take, %d readings over the take): max %.2f dB, mean %.2f dB; the take's max %.2f dB at %.1f s" % (
                TRIAD_WINDOW_S[0], TRIAD_WINDOW_S[1], result["limiter"]["readings"],
                result["limiter"]["triad_max_db"], result["limiter"]["triad_mean_db"],
                result["limiter"]["take_max_db"], result["limiter"]["take_max_at_s"])
        elif result["limiter"]:
            line = "limiter: %d readings over the take, none inside the triad's window (%.0f to %.0f s); the take's max %.2f dB at %.1f s" % (
                result["limiter"]["readings"], TRIAD_WINDOW_S[0], TRIAD_WINDOW_S[1],
                result["limiter"]["take_max_db"], result["limiter"]["take_max_at_s"])
        else:
            line = "limiter: no reading (csp diag answered nothing during the take)"
        log.append(line)
        print(line)
        print("== %s: baseline_check" % name)
        check_rc = run([sys.executable, os.path.join(HERE, "baseline_check.py"), wav,
                        "--transpose", str(baseline.transpose),
                        "--envelope", take + ".envelope.csv", "--json", take + ".check.json"], log)
        print("== %s: benchmark_compare" % name)
        compare_rc = run([sys.executable, os.path.join(HERE, "benchmark_compare.py"), wav, "--baseline", name,
                          "--plot", take + ".png", "--json", take + ".compare.json"], log)
        with open(take + ".tables.txt", "w") as out:
            out.write("\n".join(log) + "\n")
        try:
            result["check_failures"] = json.load(open(take + ".check.json")).get("failures")
            result["compare_failures"] = json.load(open(take + ".compare.json")).get("failures")
        except (OSError, ValueError):
            result["check_failures"] = result["compare_failures"] = None
        result["audio"] = {"passed": check_rc == 0 and compare_rc == 0}
        if not args.no_mp3:
            # review audio is MP3 at 320 kbps (AGENTS.md); the WAV stays for the analysis
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav,
                            "-c:a", "libmp3lame", "-b:a", "320k", "-ar", "48000", "-id3v2_version", "3",
                            take + ".mp3"])
    port.close()
    # A Program Change without a Bank Select, a soak's or a player's, is of
    # the Factory bank (bank 1) again.
    send(args.port, *bank_select(0))

    def word(ok):
        return "ok" if ok else "FAIL"

    baselines_passed = all(r["preset_loaded"] and r["audio"]["passed"] for r in verdict["baselines"].values())
    passed = self_test_passed and differing == 0 and baselines_passed
    verdict["passed"] = passed
    with open(os.path.join(args.out, "verdict.json"), "w") as out:
        json.dump(verdict, out, indent=2)
    print("== verdict: %s (self-test %s, verify %s, %s)" % (
        "PASS" if passed else "FAIL", word(self_test_passed), word(differing == 0),
        ", ".join("%s %s" % (name, "not loaded" if not r["preset_loaded"] else "audio " + word(r["audio"]["passed"]))
                  for name, r in verdict["baselines"].items())))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
