#!/usr/bin/env python3
"""BLE MIDI TX (#284): the synth sends on the MIDI characteristic, RX still works.

    Copyright © 2026 Thor H. Linløkken <thj@thj.no>
    License: CERN-OHL-S v2

Over the real Linux path (BlueZ's MIDI plugin exposes the Noaidi as the ALSA
port "Noaidi Bluetooth", both directions), with the CH345 into the panel
port as the other source:

  1. TX: a CC sent into the panel port comes out on the BLE port, the synth's
     parameter feedback to another surface (three CCs, each within 2 s).
  2. No THRU: a note sent into the panel port does not come out on BLE.
  3. RX intact, no echo: a CC and a note sent over BLE reach the firmware
     (the console's MIDI trace names their source "ble") and nothing comes
     back on BLE, since a surface never hears itself.

Two things the host taught, both kept here: the CH345's kernel bridge opens
the adapter only while a client is subscribed to its port, and the bytes a
one-shot sender (aseqsend) queues die with its close, so this script sends
through a port of its own that stays subscribed; and polling `aconnect -l`
while BlueZ sets the MIDI profile up leaves the plugin without its notify
subscription (no TX from the synth, every time), so the connection is given
a fixed six seconds instead.

Resets the ESP32 once at the start (--no-reset: only captures the console),
connects with bluetoothctl, and always disconnects and untrusts at the end:
the Noaidi takes one BLE connection, and a trusted device is auto-reconnected
by BlueZ.

    ~/.noaidi-blenv/bin/python3 tools/lab/ble/midi_tx_check.py [--port /dev/ttyACM0] [--no-reset]
"""
import argparse
import os
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ble_midi_fuzz import NOAIDI_MAC, bt  # noqa: E402

CONNECT_SECONDS = 6.0  # BlueZ: connect, encrypt, discover, accept the profile, subscribe


class Console(threading.Thread):
    """Capture the ESP32's console in the background, resetting it first or not."""

    def __init__(self, port, reset):
        super().__init__(daemon=True)
        self.port = port
        self.reset = reset
        self.lines = []
        self._stop = threading.Event()

    def run(self):
        import serial

        s = serial.Serial(self.port, 115200, timeout=0.3)
        if self.reset:
            s.setDTR(False)
            s.setRTS(True)
            time.sleep(0.1)
            s.setRTS(False)
        buf = b""
        while not self._stop.is_set():
            data = s.read(4096)
            if data:
                buf += data
                *done, tail = buf.decode(errors="replace").split("\n")
                self.lines.extend(ln.rstrip("\r") for ln in done)
                buf = tail.encode(errors="replace")
        s.close()

    def stop(self):
        self._stop.set()


def find_port(client, name):
    for p in client.list_ports():
        if name in (p.client_name or "") or name in (p.name or ""):
            return p
    return None


def open_ports():
    """Our ALSA client: an output into the CH345 (held subscribed), an output
    into the Noaidi over BLE and an input from it."""
    from alsa_midi import PortCaps, SequencerClient

    client = SequencerClient("noaidi-tx-check")
    ch345 = find_port(client, "CH345")
    noaidi = find_port(client, "Noaidi")
    if ch345 is None:
        raise RuntimeError("CH345 ALSA port not found")
    if noaidi is None:
        raise RuntimeError("Noaidi ALSA port not found: BlueZ did not expose the MIDI profile")
    panel = client.create_port("panel")
    panel.connect_to(ch345)
    out = client.create_port("ble out")
    out.connect_to(noaidi)
    inp = client.create_port("ble in", caps=PortCaps.WRITE | PortCaps.SUBS_WRITE)
    inp.connect_from(noaidi)
    print(f"[midi] '{ch345.client_name}' held; '{noaidi.client_name}:{noaidi.name}' connected both ways")
    return client, panel, out, inp


def received(client, seconds):
    """Every event that arrives on our input within the window."""
    events = []
    deadline = time.time() + seconds
    while time.time() < deadline:
        ev = client.event_input(timeout=max(0.0, deadline - time.time()))
        if ev is not None:
            events.append(ev)
    return events


def describe(ev):
    from alsa_midi import ControlChangeEvent, NoteOffEvent, NoteOnEvent

    if isinstance(ev, ControlChangeEvent):
        return f"cc {ev.param}={ev.value}"
    if isinstance(ev, NoteOnEvent):
        return f"note_on {ev.note}"
    if isinstance(ev, NoteOffEvent):
        return f"note_off {ev.note}"
    return type(ev).__name__


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/dev/ttyACM0", help="the ESP32 console")
    ap.add_argument("--no-reset", action="store_true", help="leave the ESP32 running; capture only")
    args = ap.parse_args()

    from alsa_midi import ControlChangeEvent, NoteOffEvent, NoteOnEvent

    cap = Console(args.port, reset=not args.no_reset)
    cap.start()
    time.sleep(3.0)  # the reset-boot settles; advertising begins

    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
    failures = []
    client = None
    try:
        print(f"[ble] connecting {NOAIDI_MAC}, {CONNECT_SECONDS:.0f} s for BlueZ ...")
        bt(f"connect {NOAIDI_MAC}", btctl)
        time.sleep(CONNECT_SECONDS)
        client, panel, out, inp = open_ports()
        for ln in cap.lines:
            if "ble_midi" in ln:
                print(f"[fw] {ln.strip()}")

        def send(port, ev):
            client.event_output(ev, port=port)
            client.drain_output()

        # 1. TX: a CC into the panel port comes out on BLE
        for num, val in ((74, 100), (71, 12), (7, 103)):
            received(client, 0.2)  # drain
            send(panel, ControlChangeEvent(channel=0, param=num, value=val))
            got = [describe(e) for e in received(client, 2.0)]
            print(f"[tx] panel cc {num}={val} -> BLE got {got or 'nothing'}")
            if f"cc {num}={val}" not in got:
                failures.append(f"CC {num}={val} from the panel port did not come out on BLE")

        # 2. no THRU: a note into the panel port stays off BLE
        send(panel, NoteOnEvent(note=60, channel=0, velocity=100))
        got = [describe(e) for e in received(client, 1.0)]
        send(panel, NoteOffEvent(note=60, channel=0, velocity=64))
        print(f"[thru] panel note -> BLE got {got or 'nothing'}")
        if got:
            failures.append(f"a note from the panel port came out on BLE: {got}")

        # 3. RX intact, no echo: a CC and a note over BLE reach the firmware,
        #    nothing comes back
        before = len(cap.lines)
        send(out, ControlChangeEvent(channel=0, param=24, value=10))
        send(out, NoteOnEvent(note=64, channel=0, velocity=100))
        got = [describe(e) for e in received(client, 1.0)]
        send(out, NoteOffEvent(note=64, channel=0, velocity=0))
        time.sleep(0.5)
        trace = cap.lines[before:]
        saw_cc = any("num= 24 val= 10" in ln and "ble" in ln for ln in trace)
        saw_note = any("note_on" in ln and "note= 64" in ln and "ble" in ln for ln in trace)
        print(f"[rx] BLE cc 24=10 traced: {saw_cc}; note 64 traced: {saw_note}; echoed back: {got or 'nothing'}")
        if not saw_cc:
            failures.append("a CC over BLE did not reach the firmware (RX)")
        if not saw_note:
            failures.append("a note over BLE did not reach the firmware (RX)")
        if got:
            failures.append(f"the BLE surface heard itself: {got}")

        send(panel, ControlChangeEvent(channel=0, param=123, value=0))  # notes off, whatever happened

        # The firmware logs the central's subscription; the CCs arriving is the
        # direct evidence of it, the line is the record.
        subscribed = next((ln.strip() for ln in cap.lines if "notifications on" in ln), None)
        print(f"[fw] {subscribed}" if subscribed else "[fw] (the subscription line was not in the capture)")
    finally:
        if client is not None:
            client.close()
        try:
            bt(f"disconnect {NOAIDI_MAC}", btctl)
            time.sleep(1.5)
            bt(f"untrust {NOAIDI_MAC}", btctl)
            time.sleep(0.5)
            btctl.stdin.close()
        except Exception:
            pass
        btctl.terminate()
        subprocess.run(["bluetoothctl", "disconnect", NOAIDI_MAC], capture_output=True, timeout=10)
        subprocess.run(["bluetoothctl", "untrust", NOAIDI_MAC], capture_output=True, timeout=10)
        cap.stop()
        print("[ble] disconnected + untrusted (cleanup)")

    if failures:
        print("FAIL:")
        for f in failures:
            print("  -", f)
        return 1
    print("PASS: BLE MIDI TX works, RX intact, no THRU, no echo")
    return 0


if __name__ == "__main__":
    sys.exit(main())
