#!/usr/bin/env python3
"""BLE MIDI TX (#284): the synth sends on the MIDI characteristic, RX still works.

    Copyright © 2026 Thor H. Linløkken <thj@thj.no>
    License: CERN-OHL-S v2

Over the real Linux path (BlueZ's MIDI plugin exposes the Noaidi as the ALSA
port "Noaidi Bluetooth", both directions), with the CH345 into the DIN jack
as the other source:

  1. TX: a CC sent into the DIN jack comes out on the BLE port, the synth's
     parameter feedback to another surface (three CCs, each within 2 s).
  2. No THRU: a note sent into the DIN jack does not come out on BLE.
  3. RX intact, no echo: a CC and a note sent over BLE reach the firmware
     (the console's MIDI trace names their source "ble") and nothing comes
     back on BLE, since a surface never hears itself.

Resets the ESP32 once at the start (the console capture), connects with
bluetoothctl, and always disconnects and untrusts at the end: the Noaidi
takes one BLE connection, and a trusted device is auto-reconnected by BlueZ.

    ~/.noaidi-blenv/bin/python3 tools/lab/ble/midi_tx_check.py [--port /dev/ttyACM0]
"""
import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ble_midi_fuzz import NOAIDI_MAC, SerialCapture, bt, wait_for_alsa_port  # noqa: E402

DIN_PORT = "16:0"  # the CH345 adapter, cabled into the DIN jack (tools/lab/README.md)


def din(message):
    """One MIDI message, hex bytes, into the DIN jack."""
    subprocess.run(["aseqsend", "-p", DIN_PORT, message], check=True)


def open_ble_ports():
    """Our ALSA client: an output into the Noaidi and an input from it."""
    from alsa_midi import PortCaps, SequencerClient

    client = SequencerClient("noaidi-tx-check")
    noaidi = None
    for p in client.list_ports():
        if "Noaidi" in (p.client_name or "") or "Noaidi" in (p.name or ""):
            noaidi = p
            break
    if noaidi is None:
        raise RuntimeError("Noaidi ALSA port not found")
    out = client.create_port("out")
    inp = client.create_port("in", caps=PortCaps.WRITE | PortCaps.SUBS_WRITE)
    out.connect_to(noaidi)
    inp.connect_from(noaidi)
    print(f"[midi] '{noaidi.client_name}:{noaidi.name}' connected both ways")
    return client, out, inp


def received(client, seconds):
    """Every event that arrives on our input within the window."""
    events = []
    deadline = time.time() + seconds
    while time.time() - deadline < 0:
        remaining = max(0.0, deadline - time.time())
        ev = client.event_input(timeout=remaining)
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
    args = ap.parse_args()

    from alsa_midi import ControlChangeEvent, NoteOffEvent, NoteOnEvent

    cap = SerialCapture(args.port)
    cap.start()
    time.sleep(3.0)  # the reset-boot settles; advertising begins

    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
    failures = []
    try:
        print(f"[ble] connecting {NOAIDI_MAC} ...")
        bt(f"connect {NOAIDI_MAC}", btctl)
        if not wait_for_alsa_port():
            print("FAIL: BLE ALSA port never appeared")
            return 2
        client, out, inp = open_ble_ports()
        time.sleep(1.5)  # BlueZ subscribes to the notifications on its own
        if not any("notifications on" in ln for ln in cap.lines):
            failures.append("the firmware never logged the central's subscription")

        def send_ble(ev):
            client.event_output(ev, port=out)
            client.drain_output()

        # 1. TX: a CC into the DIN jack comes out on BLE
        for num, val in ((74, 100), (71, 12), (7, 103)):
            received(client, 0.2)  # drain
            din("B0 %02X %02X" % (num, val))
            got = [describe(e) for e in received(client, 2.0)]
            print(f"[tx] DIN cc {num}={val} -> BLE got {got or 'nothing'}")
            if f"cc {num}={val}" not in got:
                failures.append(f"CC {num}={val} from the DIN jack did not come out on BLE")

        # 2. no THRU: a note into the DIN jack stays off BLE
        din("90 3C 64")
        got = [describe(e) for e in received(client, 1.0)]
        din("80 3C 40")
        print(f"[thru] DIN note -> BLE got {got or 'nothing'}")
        if got:
            failures.append(f"a note from the DIN jack came out on BLE: {got}")

        # 3. RX intact, no echo: a CC and a note over BLE reach the firmware,
        #    nothing comes back
        before = len(cap.lines)
        send_ble(ControlChangeEvent(channel=0, param=24, value=10))
        send_ble(NoteOnEvent(note=64, channel=0, velocity=100))
        got = [describe(e) for e in received(client, 1.0)]
        send_ble(NoteOffEvent(note=64, channel=0, velocity=0))
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

        din("B0 7B 00")  # notes off, whatever happened
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
