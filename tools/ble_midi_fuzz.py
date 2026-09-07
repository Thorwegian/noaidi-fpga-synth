#!/usr/bin/env python3
"""Automated BLE-MIDI stress test for Noaidi (issue #70 crash repro).

Connects to the Noaidi BLE-MIDI peripheral from a Linux host, floods it
with the exact abuse that crashes it on hardware -- continuous CC
sweeps (voice mode / volume / mix) interleaved with note on/off so the
voice pool stays busy with release tails -- while capturing the ESP32
serial. Prints any crash indicators (task watchdog, panic, backtrace)
at the end.

    python3 ble_midi_fuzz.py [seconds] [--rate MSG_PER_S] [--port DEV]

Needs bleak + pyserial (a venv is fine). Run on the Linux box that can
see the Noaidi over BLE and has the ESP on /dev/ttyACM0.
"""
import argparse
import asyncio
import threading
import time

from bleak import BleakScanner, BleakClient

MIDI_CHAR = "7772e5db-3868-4112-a1a9-f2669d106bf3"   # BLE-MIDI I/O char

CRASH_KEYS = ("wdt", "panic", "Guru", "abort", "Backtrace", "assert",
              "Rebooting", "rst:", "StoreProhibited", "LoadProhibited",
              "IllegalInstruction", "Cache disabled")


class SerialCapture(threading.Thread):
    """Capture /dev/ttyACM0 in the background, resetting once at start."""

    def __init__(self, port):
        super().__init__(daemon=True)
        self.port = port
        self.lines = []
        self._stop = threading.Event()
        self.ok = False

    def run(self):
        try:
            import serial
        except ImportError:
            print("[cap] pyserial missing"); return
        try:
            s = serial.Serial(self.port, 115200, timeout=0.3)
        except Exception as e:
            print(f"[cap] cannot open {self.port}: {e}"); return
        self.ok = True
        # Clean reset pulse so we start from a known boot.
        s.setDTR(False); s.setRTS(True); time.sleep(0.1); s.setRTS(False)
        buf = b""
        while not self._stop.is_set():
            d = s.read(4096)
            if d:
                buf += d
                text = buf.decode(errors="replace")
                *done, buf_tail = text.split("\n")
                for ln in done:
                    self.lines.append(ln.rstrip("\r"))
                buf = buf_tail.encode(errors="replace")
        s.close()

    def stop(self):
        self._stop.set()


def midi_packet(msgs):
    """Wrap (status,d1,d2) messages in one BLE-MIDI packet."""
    ms = int(time.time() * 1000) & 0x1FFF
    hdr = 0x80 | ((ms >> 7) & 0x3F)
    tsl = 0x80 | (ms & 0x7F)
    out = bytearray([hdr])
    for st, d1, d2 in msgs:
        out += bytes([tsl, st, d1, d2])
    return bytes(out)


async def fuzz(duration, rate):
    print("[ble] scanning for Noaidi ...")
    dev = await BleakScanner.find_device_by_filter(
        lambda d, a: (d.name or "").startswith("Noaidi"), timeout=15.0)
    if not dev:
        print("[ble] Noaidi not found"); return 2
    print(f"[ble] found {dev.address}, connecting ...")
    async with BleakClient(dev) as cli:
        ch = None
        for svc in cli.services:
            for c in svc.characteristics:
                if c.uuid.lower() == MIDI_CHAR:
                    ch = c
        if ch is None:
            print("[ble] MIDI characteristic not found"); return 3
        print(f"[ble] connected; flooding for {duration:.0f}s at ~{rate}/s")

        delay = max(0.0, 4.0 / rate)   # 4 messages per batch
        notes = [52, 55, 57, 60, 64, 48]
        t0 = time.time()
        cc = ni = n = 0
        while time.time() - t0 < duration:
            cc = (cc + 3) & 0x7F
            note = notes[ni % len(notes)]; ni += 1
            batch = [
                (0xB0, 26, cc),                 # voice mode sweep (the trigger)
                (0xB0, 7, (cc * 2) & 0x7F),     # master volume sweep
                (0xB0, 24, cc),                 # osc mix sweep
                (0x90, note, 40) if ni % 2 else (0x80, note, 0),
            ]
            try:
                await cli.write_gatt_char(ch, midi_packet(batch), response=False)
            except Exception as e:
                print(f"[ble] write failed after {n} batches: {e}")
                print("[ble] (device likely crashed / disconnected)")
                return 1
            n += 1
            if delay:
                await asyncio.sleep(delay)
        # all-notes-off so nothing is stuck if it survived
        try:
            await cli.write_gatt_char(
                ch, midi_packet([(0xB0, 123, 0)]), response=False)
        except Exception:
            pass
        print(f"[ble] sent {n} batches ({n*4} messages) in "
              f"{time.time()-t0:.1f}s -- survived")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("seconds", nargs="?", type=float, default=40.0)
    ap.add_argument("--rate", type=int, default=1200,
                    help="target MIDI messages/sec (BLE may cap lower)")
    ap.add_argument("--port", default="/dev/ttyACM0")
    args = ap.parse_args()

    cap = SerialCapture(args.port); cap.start()
    time.sleep(3.0)   # let the reset-boot settle before flooding
    rc = asyncio.run(fuzz(args.seconds, args.rate))
    time.sleep(1.5); cap.stop(); cap.join(timeout=3)

    print("\n=== serial crash indicators ===")
    hits = [l for l in cap.lines if any(k in l for k in CRASH_KEYS)]
    if hits:
        for l in hits[-80:]:
            print(l)
        rc = rc or 1
    else:
        print("(none)")
    dropped = [l for l in cap.lines if "dropped" in l]
    print(f"=== {len(cap.lines)} serial lines, {len(dropped)} 'dropped' warnings, "
          f"{len(hits)} crash lines ===")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
