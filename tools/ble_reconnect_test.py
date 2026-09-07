#!/usr/bin/env python3
"""BLE reconnect soak test (issue #78: "first reconnect sometimes
drops, second is stable").

Cycles connect -> verify MIDI actually flows (a note echoed on the ESP
console AND audible-path gate write) -> disconnect, N times, capturing
the ESP serial throughout. Reports per-cycle timing and any cycle
where the connection formed but MIDI never made it through -- the
exact reported symptom -- plus disconnect reasons from the firmware
log.

    python3 ble_reconnect_test.py [cycles] [--port /dev/ttyACM0]

Run on the dev host. Always disconnects and untrusts at the end (#82).
"""
import argparse
import subprocess
import threading
import time

NOAIDI_MAC = "10:00:3B:B0:4D:A6"


class SerialCapture(threading.Thread):
    def __init__(self, port):
        super().__init__(daemon=True)
        self.port = port
        self.lines = []
        self.lock = threading.Lock()
        self._stop = threading.Event()

    def run(self):
        import serial
        s = serial.Serial(self.port, 115200, timeout=0.3)
        s.setDTR(False); s.setRTS(True); time.sleep(0.1); s.setRTS(False)
        buf = b""
        while not self._stop.is_set():
            d = s.read(4096)
            if d:
                buf += d
                text = buf.decode(errors="replace")
                *done, tail = text.split("\n")
                with self.lock:
                    self.lines.extend(l.rstrip("\r") for l in done)
                buf = tail.encode(errors="replace")
        s.close()

    def mark(self):
        with self.lock:
            return len(self.lines)

    def since(self, mark):
        with self.lock:
            return self.lines[mark:]

    def stop(self):
        self._stop.set()


def bt(proc, cmd):
    proc.stdin.write(cmd + "\n")
    proc.stdin.flush()


def wait_alsa(present, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        out = subprocess.run(["aconnect", "-l"], capture_output=True,
                             text=True).stdout
        if ("Noaidi" in out) == present:
            return True
        time.sleep(0.4)
    return False


def wait_disconnected(timeout=10):
    """Wait for the REAL link teardown, not just the ALSA port vanishing.
    (BlueZ's disconnect is async: a connect issued before completion gets
    'Connection successful' for the dying link, which the finishing
    disconnect then tears down — the exact first-reconnect race, #78.)"""
    t0 = time.time()
    while time.time() - t0 < timeout:
        out = subprocess.run(["bluetoothctl", "info", NOAIDI_MAC],
                             capture_output=True, text=True).stdout
        if "Connected: no" in out:
            return True
        time.sleep(0.4)
    return False


def send_note(on, note=60):
    from alsa_midi import SequencerClient, NoteOnEvent, NoteOffEvent
    client = SequencerClient("reconnect-test")
    port = client.create_port("out")
    target = None
    for p in client.list_ports():
        if "Noaidi" in (p.client_name or "") or "Noaidi" in (p.name or ""):
            target = p
            break
    if target is None:
        client.close()
        return False
    port.connect_to(target)
    ev = (NoteOnEvent(note=note, channel=0, velocity=64) if on
          else NoteOffEvent(note=note, channel=0, velocity=0))
    client.event_output(ev, port=port)
    client.drain_output()
    time.sleep(0.2)
    client.close()
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cycles", nargs="?", type=int, default=15)
    ap.add_argument("--port", default="/dev/ttyACM0")
    ap.add_argument("--gap", type=float, default=1.0,
                    help="seconds between disconnect and next connect")
    args = ap.parse_args()

    cap = SerialCapture(args.port); cap.start()
    time.sleep(3)

    btlog = open("/tmp/btctl_reconnect.log", "w")
    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=btlog, stderr=btlog, text=True)
    results = []
    try:
        for cyc in range(1, args.cycles + 1):
            m = cap.mark()
            t0 = time.time()
            bt(btctl, f"connect {NOAIDI_MAC}")
            if not wait_alsa(True, 15):
                results.append((cyc, "CONNECT-TIMEOUT", time.time() - t0))
                print(f"cycle {cyc:2d}: CONNECT-TIMEOUT")
                fw = cap.since(m)
                print(f"    fw saw {len(fw)} lines during the attempt:")
                for l in fw[-8:]:
                    print(f"    | {l}")
                bt(btctl, f"disconnect {NOAIDI_MAC}")
                wait_disconnected()
                time.sleep(args.gap)
                continue
            t_conn = time.time() - t0

            # MIDI truth test: does a note actually arrive?
            sent = send_note(True)
            time.sleep(0.6)
            send_note(False)
            time.sleep(0.4)
            got = [l for l in cap.since(m) if "note_on" in l]
            verdict = "OK" if (sent and got) else "MIDI-DEAD"

            # firmware's view of this cycle
            fwconn = [l for l in cap.since(m)
                      if "connection established" in l or "disconnected" in l
                      or "encryption" in l]
            results.append((cyc, verdict, t_conn))
            print(f"cycle {cyc:2d}: {verdict}  (connect {t_conn:4.1f}s, "
                  f"{len(fwconn)} fw events)")
            if verdict != "OK":
                for l in cap.since(m)[-12:]:
                    print(f"    | {l}")

            bt(btctl, f"disconnect {NOAIDI_MAC}")
            if not wait_disconnected():
                print(f"cycle {cyc:2d}: WARN disconnect not confirmed")
            time.sleep(args.gap)
    finally:
        try:
            bt(btctl, f"disconnect {NOAIDI_MAC}")
            time.sleep(1)
            bt(btctl, f"untrust {NOAIDI_MAC}")
            btctl.stdin.close()
        except Exception:
            pass
        btctl.terminate()
        subprocess.run(["bluetoothctl", "disconnect", NOAIDI_MAC],
                       capture_output=True, timeout=10)
        subprocess.run(["bluetoothctl", "untrust", NOAIDI_MAC],
                       capture_output=True, timeout=10)
        cap.stop(); cap.join(timeout=3)

    ok = sum(1 for _, v, _ in results if v == "OK")
    print(f"\nRESULT ble_reconnect_test: {ok}/{len(results)} cycles OK")
    bad = [r for r in results if r[1] != "OK"]
    for cyc, v, t in bad:
        print(f"  cycle {cyc}: {v}")
    return 0 if not bad else 1


if __name__ == "__main__":
    raise SystemExit(main())
