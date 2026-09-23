#!/usr/bin/env python3
"""Find a stimulus that actually reaches the master limiter (#121 M2).

Two attempts at the RMS acceptance test came back INVALID: peak -15.7 dBFS
(5 notes, plain) and -35.1 dBFS (5 notes, 7+1 unison) against a -1 dBFS
threshold. Unison came out QUIETER, which I do not understand yet. So:
measure the peak for a ladder of stimuli and report which, if any, gets
within 3 dB of the threshold. No verdicts here -- level only."""
import subprocess, sys, time, struct
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC

AUDIO_DEV = "hw:1,0"; RATE = 48000

BASE = [(20, 0), (24, 0), (27, 0), (28, 0), (86, 0), (87, 0), (29, 0), (30, 127),
        (74, 110), (71, 20), (73, 127), (75, 0), (79, 127), (72, 100),
        (107, 64), (77, 0), (110, 0), (7, 127), (10, 64)]

LADDER = [
    ("plain,  5 notes, vel 127",          0,  [45, 52, 57, 61, 64]),
    ("plain, 10 notes, vel 127",          0,  [36, 40, 43, 45, 48, 52, 55, 57, 60, 64]),
    ("unison 7+1 (CC26=64), 5 notes",     64, [45, 52, 57, 61, 64]),
    ("unison 4+4 (CC26=127), 5 notes",    127,[45, 52, 57, 61, 64]),
    ("unison 7+1, 10 notes",              64, [36, 40, 43, 45, 48, 52, 55, 57, 60, 64]),
]

def capture(sec):
    r = subprocess.run(["arecord", "-D", AUDIO_DEV, "-f", "S16_LE", "-r", str(RATE), "-c", "2",
                        "-t", "raw", "-q", "-d", str(sec)], capture_output=True)
    n = len(r.stdout) // 2
    return np.array(struct.unpack(f"<{n}h", r.stdout)[0::2], dtype=float)

def main():
    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True)
    try:
        bt(f"connect {NOAIDI_MAC}", btctl)
        if not wait_for_alsa_port(): print("FAIL: no BLE port"); return 2
        client, port = open_midi_out()
        from alsa_midi import NoteOnEvent, NoteOffEvent, ControlChangeEvent
        def send(ev): client.event_output(ev, port=port); client.drain_output()
        def cc(n, v): send(ControlChangeEvent(channel=0, param=n, value=v))
        for n, v in BASE: cc(n, v); time.sleep(0.03)
        print("  stimulus                              peak dBFS   50ms-RMS range      limiter?")
        for label, mode, notes in LADDER:
            cc(26, mode); cc(120, 0); time.sleep(0.4)
            for n in notes: send(NoteOnEvent(note=n, channel=0, velocity=127))
            time.sleep(0.5)
            x = capture(2)
            for n in notes: send(NoteOffEvent(note=n, channel=0, velocity=0))
            cc(120, 0); time.sleep(0.4)
            if len(x) < 4096 or np.abs(x).max() == 0:
                print(f"  {label:<36} RIG SILENT"); continue
            pk = 20*np.log10(np.abs(x).max()/32768.0)
            w = RATE//20; xs = x[int(0.3*RATE):]
            rms = [20*np.log10(max(np.sqrt(np.mean(xs[i*w:(i+1)*w]**2)),1e-9)/32768.0) for i in range(len(xs)//w)]
            eng = "ENGAGED" if pk >= -3.0 else ("close" if pk >= -6.0 else "no")
            print(f"  {label:<36} {pk:7.1f}     {min(rms):6.1f}..{max(rms):6.1f} dB   {eng}")
        cc(26, 0); cc(7, 100); client.close()
    finally:
        try:
            bt(f"disconnect {NOAIDI_MAC}", btctl); time.sleep(1.5)
            bt(f"untrust {NOAIDI_MAC}", btctl); btctl.stdin.close()
        except Exception: pass
        btctl.terminate()
        subprocess.run(["bluetoothctl", "disconnect", NOAIDI_MAC], capture_output=True, timeout=10)
        subprocess.run(["bluetoothctl", "untrust", NOAIDI_MAC], capture_output=True, timeout=10)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
