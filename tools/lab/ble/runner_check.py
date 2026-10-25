#!/usr/bin/env python3
"""The O.S.C. runner across a board reset (#287).

    Copyright © 2026 Thor H. Linløkken <thj@thj.no>
    License: CERN-OHL-S v2

Starts tools/osc_panel/runner.py, plays Open Stage Control's part on its port
"Noaidi O.S.C.:surface" (subscribed for input, connected for output), and:

  1. waits for the runner to link and the synth's state to arrive: the whole
     preset as CCs on the surface port, each once;
  2. resets the board through the console's RTS and waits for the runner to
     reconnect, re-link and ask again: the whole preset arrives once more,
     within RESET_BUDGET seconds, with nothing done on O.S.C.'s side;
  3. sends a Program Change from the surface port: the synth's dump comes
     back, which proves the relay's other direction without the console.

Always stops the runner, disconnects and untrusts at the end.

    ~/.noaidi-blenv/bin/python3 tools/lab/ble/runner_check.py [--port /dev/ttyACM0]
"""
import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from ble_midi_fuzz import NOAIDI_MAC  # noqa: E402
from feedback_check import DUMP  # noqa: E402
from midi_tx_check import Console, find_port, received  # noqa: E402

RUNNER = os.path.join(HERE, "..", "..", "osc_panel", "runner.py")
RESET_BUDGET = 40.0  # seconds from the reset to the state's return (reconnect, link delay, dump)


def ccs_of(events):
    from alsa_midi import ControlChangeEvent

    return [(e.param, e.value) for e in events if isinstance(e, ControlChangeEvent)]


def wait_for_dump(client, budget):
    """The CCs that arrive within the budget, stopping once a whole dump is in."""
    got = []
    deadline = time.time() + budget
    while time.time() < deadline and len(got) < len(DUMP):
        got += ccs_of(received(client, 1.0))
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/dev/ttyACM0", help="the ESP32 console")
    args = ap.parse_args()

    from alsa_midi import PortCaps, ProgramChangeEvent, SequencerClient

    cap = Console(args.port, reset=False)
    cap.start()
    runner = subprocess.Popen([sys.executable, RUNNER], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    failures = []
    client = None
    try:
        # O.S.C.'s part: find the runner's port, subscribe both ways
        client = SequencerClient("osc-stand-in")
        surface = None
        for _ in range(40):
            surface = find_port(client, "Noaidi O.S.C.")
            if surface is not None:
                break
            time.sleep(0.5)
        if surface is None:
            print("FAIL: the runner's port never appeared")
            return 2
        out = client.create_port("to runner")
        inp = client.create_port("from runner", caps=PortCaps.WRITE | PortCaps.SUBS_WRITE)
        out.connect_to(surface)
        inp.connect_from(surface)
        print("[osc] on the runner's surface port, both ways")

        # 1. the first link and the state
        got = wait_for_dump(client, RESET_BUDGET)
        print(f"[link] {len(got)} CCs from the synth after the runner linked (want {len(DUMP)})")
        if [cc for cc, _ in got] != DUMP:
            failures.append(f"the first state was {len(got)} CCs, not the preset")

        # 2. the board resets; the runner must bring the state back by itself
        received(client, 0.5)
        t0 = time.time()
        cap.stop()
        time.sleep(0.5)
        cap = Console(args.port, reset=True)
        cap.start()
        print("[reset] the board was reset through RTS")
        got = wait_for_dump(client, RESET_BUDGET)
        took = time.time() - t0
        print(f"[reset] {len(got)} CCs from the synth {took:.1f} s after the reset (want {len(DUMP)})")
        if [cc for cc, _ in got] != DUMP:
            failures.append(f"after the reset the state was {len(got)} CCs within {RESET_BUDGET:.0f} s, not the preset")

        # 3. the relay's other direction, observed through MIDI: a Program
        #    Change from O.S.C.'s side reaches the synth, which dumps the preset
        #    back to the surface port
        received(client, 0.5)
        client.event_output(ProgramChangeEvent(channel=0, value=1), port=out)
        client.drain_output()
        got = wait_for_dump(client, 5.0)
        print(f"[relay] a Program Change from the surface port brought {len(got)} CCs back (want {len(DUMP)})")
        if [cc for cc, _ in got] != DUMP:
            failures.append("a Program Change from the surface port did not reach the synth, or its dump did not come back")
    finally:
        if client is not None:
            client.close()
        runner.terminate()
        try:
            runner.wait(timeout=5)
        except subprocess.TimeoutExpired:
            runner.kill()
        print("[runner] log:")
        for ln in (runner.stdout.read() if runner.stdout else "").splitlines():
            print("   ", ln)
        subprocess.run(["bluetoothctl", "disconnect", NOAIDI_MAC], capture_output=True, timeout=10)
        subprocess.run(["bluetoothctl", "untrust", NOAIDI_MAC], capture_output=True, timeout=10)
        cap.stop()
        print("[ble] disconnected + untrusted (cleanup)")

    if failures:
        print("FAIL:")
        for f in failures:
            print("  -", f)
        return 1
    print("PASS: the runner brings the state back across a board reset, both directions relayed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
