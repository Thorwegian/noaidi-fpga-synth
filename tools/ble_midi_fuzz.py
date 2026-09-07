#!/usr/bin/env python3
"""Automated BLE-MIDI stress test for Noaidi (issues #70/#80/#82).

Floods the Noaidi with the abuse that used to crash it -- continuous CC
sweeps (voice mode / volume / mix) interleaved with note on/off -- over
the REAL Linux BLE-MIDI path, while capturing the ESP32 serial and
reporting crash indicators.

How the path works (learned the hard way, #82): BlueZ has a built-in
BLE-MIDI plugin that CLAIMS the MIDI service the moment the Noaidi
connects, exposing an ALSA sequencer port ("Noaidi Bluetooth") and
marking the service read-only for D-Bus GATT clients -- raw
bleak/busctl writes bounce with org.bluez.Error.NotAuthorized without
ever reaching the air. So: connect with bluetoothctl, then send MIDI
through the ALSA port like any Linux DAW would.

    python3 ble_midi_fuzz.py [seconds] [--rate MSG_PER_S] [--port DEV]

Needs alsa-midi + pyserial (venv is fine) and a BlueZ built with the
MIDI plugin (stock on this dev host). ALWAYS disconnects and
untrusts when done -- the Noaidi accepts a single BLE connection, and a
trusted device gets auto-reconnected by BlueZ, blocking the phone.
"""
import argparse
import subprocess
import threading
import time

NOAIDI_MAC = "10:00:3B:B0:4D:A6"

CRASH_KEYS = ("wdt", "panic", "Guru", "abort", "Backtrace", "assert",
              "Rebooting", "rst:", "StoreProhibited", "LoadProhibited",
              "IllegalInstruction", "Cache disabled")


class SerialCapture(threading.Thread):
    """Capture the ESP console in the background, resetting once at start."""

    def __init__(self, port):
        super().__init__(daemon=True)
        self.port = port
        self.lines = []
        self._stop = threading.Event()

    def run(self):
        try:
            import serial
            s = serial.Serial(self.port, 115200, timeout=0.3)
        except Exception as e:
            print(f"[cap] cannot open {self.port}: {e}")
            return
        s.setDTR(False); s.setRTS(True); time.sleep(0.1); s.setRTS(False)
        buf = b""
        while not self._stop.is_set():
            d = s.read(4096)
            if d:
                buf += d
                text = buf.decode(errors="replace")
                *done, tail = text.split("\n")
                self.lines.extend(ln.rstrip("\r") for ln in done)
                buf = tail.encode(errors="replace")
        s.close()

    def stop(self):
        self._stop.set()


def bt(cmdline, proc=None):
    """Send one command through the persistent bluetoothctl session."""
    proc.stdin.write(cmdline + "\n")
    proc.stdin.flush()


def wait_for_alsa_port(timeout=20.0):
    """Poll aconnect -l until the BlueZ MIDI plugin exposes the Noaidi."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        out = subprocess.run(["aconnect", "-l"], capture_output=True,
                             text=True).stdout
        if "Noaidi" in out:
            return True
        time.sleep(0.5)
    return False


def open_midi_out():
    from alsa_midi import SequencerClient
    client = SequencerClient("noaidi-fuzz")
    port = client.create_port("out")
    target = None
    for p in client.list_ports():
        if "Noaidi" in (p.client_name or "") or "Noaidi" in (p.name or ""):
            target = p
            break
    if target is None:
        raise RuntimeError("Noaidi ALSA port not found")
    print(f"[midi] connecting to '{target.client_name}:{target.name}'")
    port.connect_to(target)
    return client, port


def flood(client, port, duration, rate):
    from alsa_midi import (NoteOnEvent, NoteOffEvent, ControlChangeEvent)
    notes = [52, 55, 57, 60, 64, 48]
    delay = 4.0 / rate            # 4 messages per batch
    t0 = time.time()
    cc = ni = n = 0

    def send(ev):
        client.event_output(ev, port=port)

    while time.time() - t0 < duration:
        cc = (cc + 3) & 0x7F
        note = notes[ni % len(notes)]
        send(ControlChangeEvent(channel=0, param=26, value=cc))
        send(ControlChangeEvent(channel=0, param=7, value=(cc * 2) & 0x7F))
        send(ControlChangeEvent(channel=0, param=24, value=cc))
        if ni & 1:
            send(NoteOffEvent(note=note, channel=0, velocity=0))
        else:
            send(NoteOnEvent(note=note, channel=0, velocity=40))
        client.drain_output()
        ni += 1; n += 4
        if delay > 0:
            time.sleep(delay)
    send(ControlChangeEvent(channel=0, param=123, value=0))
    client.drain_output()
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("seconds", nargs="?", type=float, default=40.0)
    ap.add_argument("--rate", type=int, default=1000,
                    help="target MIDI messages/sec")
    ap.add_argument("--port", default="/dev/ttyACM0")
    args = ap.parse_args()

    cap = SerialCapture(args.port); cap.start()
    time.sleep(3.0)   # let the reset-boot settle

    # Persistent bluetoothctl session holds the BLE connection open for
    # the duration (BlueZ drops unreferenced connections).
    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True)
    rc = 0
    try:
        print(f"[ble] connecting {NOAIDI_MAC} ...")
        bt(f"connect {NOAIDI_MAC}", btctl)
        if not wait_for_alsa_port():
            print("[ble] ALSA port never appeared -- is the Noaidi on/advertising?")
            return 2
        client, port = open_midi_out()
        print(f"[midi] flooding for {args.seconds:.0f}s at ~{args.rate}/s")
        n = flood(client, port, args.seconds, args.rate)
        client.close()
        print(f"[midi] sent {n} messages -- survived")
    finally:
        # ALWAYS free the Noaidi's single connection, and untrust so
        # BlueZ does not auto-grab it away from the phone (#82).
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

    time.sleep(1.5); cap.stop(); cap.join(timeout=3)

    print("\n=== serial crash indicators ===")
    hits = [l for l in cap.lines if any(k in l for k in CRASH_KEYS)]
    if hits:
        for l in hits[-60:]:
            print(l)
        rc = rc or 1
    else:
        print("(none)")
    dropped = [l for l in cap.lines if "dropped" in l]
    midi_seen = [l for l in cap.lines
                 if "note_on" in l or "note_off" in l or "cc " in l]
    print(f"=== {len(cap.lines)} serial lines, {len(midi_seen)} MIDI echoes, "
          f"{len(dropped)} dropped-warnings, {len(hits)} crash lines ===")
    if not midi_seen:
        print("WARNING: no MIDI echoed on the console -- flood may not have "
              "reached the synth")
        rc = rc or 3
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
