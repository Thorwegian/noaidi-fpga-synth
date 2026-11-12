#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""The three acceptances of a bitstream on the board, as one run (#238):

  1. the boot's self-test: the chip does what the model says;
  2. `csp verify`: every register the firmware wrote, read back through the
     probe, none differing;
  3. the Galaxy sequence recorded over S/PDIF, through baseline_check.py
     (Essentia) and benchmark_compare.py against the benchmark (tools/lab/
     benchmark): envelope, pitch classes, centroid, partials, valley floor.

While the sequence records, DIAG_LIMITER (docs/memory_map.md, 0x00A: the
master limiter's applied gain, linear, UQ0.18) is polled over the
console about four times a second, so the take says how much the limiter
worked during the triad (#355): the maximum and the mean over the triad's
window and the take's maximum with its time, the series as
<label>.limiter.csv. It is a reading, not a check: a borderline triad level
has its explanation in the same output.

WARNING: 3. measures the Factory preset Galaxy, still being voiced on the
bench (#305): a change to its file moves the reference, so an audio failure
after one may be the preset, not the build. See benchmark_compare.py.

usage: acceptance.py --out DIR [--label NAME] [--fs BITSTREAM] [--loader PATH]
                     [--console /dev/ttyACM0] [--port 16:0] [--device hw:1,0]
                     [--preset /Presets/Factory/Pads/Galaxy.toml] [--boot-seconds 16]
                     [--tail 24] [--no-mp3]

With --fs the bitstream is loaded first (openFPGALoader, SRAM). The ESP32 is
reset through the console's RTS and its boot log read; then the preset is
loaded, the sequence recorded (baseline_recording.py), checked and compared,
and the recording encoded as MP3 at 320 kbps (libmp3lame) for the ticket. DIR gets the
recording, the tables, the plot, the boot log, the limiter series and verdict.json; the exit
status is 0 when all three pass. Run it with the interpreter Essentia is
installed in.
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
from chip_check import ANSI, command  # noqa: E402

SELF_TEST_PASS = "self-test: the chip does what the model says"
SELF_TEST_FAIL = "THE CHIP DOES NOT DO WHAT THE MODEL SAYS"
BOOT_IMAGE = re.compile(r"boot image: ([^\r\n]{0,100})")
PROGRAM = re.compile(r"control program loaded: ([^\r\n]{0,100})")
VERIFIED = re.compile(r"verified: (\d+) register")
DIAG = re.compile(r"passes (\d+)\s+queue \S+\s+limiter (\S+)\s+dropped (\d+)")
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


def boot(port, seconds):
    """Reset the ESP32 and return its boot log, ANSI stripped."""
    port.reset_input_buffer()
    port.dtr = False
    port.rts = True
    time.sleep(0.2)
    port.rts = False
    end = time.time() + seconds
    chunks = []
    while time.time() < end:
        data = port.read(4096)
        if data:
            chunks.append(data.decode("utf-8", "replace"))
    return ANSI.sub("", "".join(chunks))


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
    parser.add_argument("--out", required=True, help="the directory for the recording, the tables and the verdict")
    parser.add_argument("--label", default="galaxy", help="the files' base name")
    parser.add_argument("--fs", help="load this bitstream first (SRAM)")
    parser.add_argument("--loader", default="openFPGALoader", help="--fs: the loader")
    parser.add_argument("--console", default="/dev/ttyACM0", help="the firmware's serial console")
    parser.add_argument("--port", default="16:0", help="the ALSA sequencer port of the synth")
    parser.add_argument("--device", default="hw:1,0", help="the ALSA capture device of the S/PDIF input")
    parser.add_argument("--preset", default="/Presets/Factory/Pads/Galaxy.toml", help="the preset, on the firmware's storage")
    parser.add_argument("--boot-seconds", type=float, default=16.0, help="how long the boot log is read")
    parser.add_argument("--tail", type=float, default=24.0, help="seconds recorded after the triad's release")
    parser.add_argument("--no-mp3", action="store_true", help="no MP3 for the ticket")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    base = os.path.join(args.out, args.label)
    verdict = {"label": args.label, "bitstream": args.fs, "when": time.strftime("%Y-%m-%dT%H:%M:%S")}
    log = []

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

    # 3. the preset, the sequence, the checks
    print("== preset")
    load = command(port, "load " + args.preset, 3.0)
    verdict["preset_loaded"] = "loaded" in load
    print("loaded" if verdict["preset_loaded"] else load.strip()[-160:])
    time.sleep(1.0)
    diag = DIAG.search(command(port, "csp diag", 2.0))
    verdict["diag"] = {"passes": int(diag.group(1)), "limiter": diag.group(2), "dropped": int(diag.group(3))} if diag else None

    wav = base + ".wav"
    print("== recording")
    readings, stop = [], threading.Event()
    poller = threading.Thread(target=poll_limiter, args=(port, readings, stop, time.monotonic()), daemon=True)
    poller.start()
    run([sys.executable, os.path.join(HERE, "baseline_recording.py"), wav, "--program", "-1",
         "--tail", str(args.tail), "--port", args.port, "--device", args.device], log)
    stop.set()
    poller.join()
    port.close()
    with open(base + ".limiter.csv", "w") as out:
        out.write("time_s,reduction_db\n")
        for t, db in readings:
            out.write("%.2f,%.3f\n" % (t, db))
    verdict["limiter"] = limiter_summary(readings)
    if verdict["limiter"] and verdict["limiter"]["triad_max_db"] is not None:
        line = "limiter during the triad (%.0f to %.0f s of the take, %d readings over the take): max %.2f dB, mean %.2f dB; the take's max %.2f dB at %.1f s" % (
            TRIAD_WINDOW_S[0], TRIAD_WINDOW_S[1], verdict["limiter"]["readings"],
            verdict["limiter"]["triad_max_db"], verdict["limiter"]["triad_mean_db"],
            verdict["limiter"]["take_max_db"], verdict["limiter"]["take_max_at_s"])
    elif verdict["limiter"]:
        line = "limiter: %d readings over the take, none inside the triad's window (%.0f to %.0f s); the take's max %.2f dB at %.1f s" % (
            verdict["limiter"]["readings"], TRIAD_WINDOW_S[0], TRIAD_WINDOW_S[1],
            verdict["limiter"]["take_max_db"], verdict["limiter"]["take_max_at_s"])
    else:
        line = "limiter: no reading (csp diag answered nothing during the take)"
    log.append(line)
    print(line)
    print("== baseline_check")
    check_rc = run([sys.executable, os.path.join(HERE, "baseline_check.py"), wav,
                    "--envelope", base + ".envelope.csv", "--json", base + ".check.json"], log)
    print("== benchmark_compare")
    compare_rc = run([sys.executable, os.path.join(HERE, "benchmark_compare.py"), wav,
                      "--plot", base + ".png", "--json", base + ".compare.json"], log)
    with open(base + ".tables.txt", "w") as out:
        out.write("\n".join(log) + "\n")
    try:
        verdict["check_failures"] = json.load(open(base + ".check.json")).get("failures")
        verdict["compare_failures"] = json.load(open(base + ".compare.json")).get("failures")
    except (OSError, ValueError):
        verdict["check_failures"] = verdict["compare_failures"] = None
    verdict["audio"] = {"passed": check_rc == 0 and compare_rc == 0}
    if not args.no_mp3:
        # review audio is MP3 at 320 kbps (AGENTS.md); the WAV stays for the analysis
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav,
                        "-c:a", "libmp3lame", "-b:a", "320k", "-ar", "48000", "-id3v2_version", "3",
                        base + ".mp3"])

    passed = self_test_passed and differing == 0 and verdict["audio"]["passed"]
    verdict["passed"] = passed
    with open(os.path.join(args.out, "verdict.json"), "w") as out:
        json.dump(verdict, out, indent=2)
    print("== verdict: %s (self-test %s, verify %s, audio %s)" % (
        "PASS" if passed else "FAIL", "ok" if self_test_passed else "FAIL",
        "ok" if differing == 0 else "FAIL", "ok" if verdict["audio"]["passed"] else "FAIL"))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
