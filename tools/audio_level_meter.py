#!/usr/bin/env python3
"""Live capture-level meter for the Noaidi audio chain (issue #81).

Chain: Noaidi analog out -> Focusrite (preamp/monitor) -> ICUSBAUDIO7D
line-in -> ALSA. Two gain stages to set: the Focusrite output/gain
knob (so the StarTech's input stage doesn't clip) and the ALSA capture
level. This prints a live peak meter so both can be dialed against a
steady tone instead of guesswork.

    python3 audio_level_meter.py [seconds] [--device hw:1,0] [--midi]

--midi holds a C-major chord over the BLE-MIDI ALSA port for the
duration (needs the Noaidi connected via BLE, see ble_midi_fuzz.py);
without it, play the keyboard yourself while watching the meter.

Target: steady peaks around -6 dBFS. The meter warns above -1 dBFS
(clipping) and below -30 dBFS (too quiet, wasting ADC bits).

ALSA level knobs on the StarTech (card 1):
    amixer -c 1 sset 'PCM Capture Source' Line
    amixer -c 1 sset 'Line' <0-100%> cap
"""
import argparse
import struct
import subprocess
import sys
import time

RATE = 48000
CHANNELS = 2
BLOCK = RATE // 4   # 0.25 s per meter update


def db(x):
    import math
    if x <= 0:
        return -96.0
    return 20.0 * math.log10(x / 32768.0)


def bar(dbfs, width=50):
    # -60 dB .. 0 dB across the bar
    fill = max(0, min(width, int((dbfs + 60) / 60 * width)))
    return "#" * fill + "-" * (width - fill)


def midi_chord_start():
    from alsa_midi import SequencerClient, NoteOnEvent
    client = SequencerClient("level-meter")
    port = client.create_port("out")
    target = None
    for p in client.list_ports():
        if "Noaidi" in (p.client_name or "") or "Noaidi" in (p.name or ""):
            target = p
            break
    if target is None:
        raise RuntimeError("Noaidi ALSA MIDI port not found (BLE connected?)")
    port.connect_to(target)
    for note in (48, 60, 64, 67):
        client.event_output(NoteOnEvent(note=note, channel=0, velocity=100),
                            port=port)
    client.drain_output()
    return client, port


def midi_chord_stop(client, port):
    from alsa_midi import ControlChangeEvent
    client.event_output(ControlChangeEvent(channel=0, param=123, value=0),
                        port=port)
    client.drain_output()
    client.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("seconds", nargs="?", type=float, default=30.0)
    ap.add_argument("--device", default="hw:1,0")
    ap.add_argument("--midi", action="store_true",
                    help="hold a test chord over BLE MIDI for the duration")
    args = ap.parse_args()

    midi = None
    if args.midi:
        midi = midi_chord_start()
        print("[midi] holding C-major chord")
        time.sleep(0.3)

    rec = subprocess.Popen(
        ["arecord", "-D", args.device, "-f", "S16_LE", "-r", str(RATE),
         "-c", str(CHANNELS), "-t", "raw", "-q"],
        stdout=subprocess.PIPE)

    peak_session = 0
    clipped = 0
    t0 = time.time()
    try:
        while time.time() - t0 < args.seconds:
            data = rec.stdout.read(BLOCK * CHANNELS * 2)
            if not data:
                print("capture stream ended early"); break
            n = len(data) // 2
            samples = struct.unpack(f"<{n}h", data)
            peak = max(max(samples), -min(samples))
            peak_session = max(peak_session, peak)
            clipped += sum(1 for s in samples if s >= 32767 or s <= -32768)
            d = db(peak)
            flag = " CLIP!" if d > -1.0 else (" (quiet)" if d < -30.0 else "")
            print(f"\r{bar(d)} {d:6.1f} dBFS{flag}   ", end="", flush=True)
    finally:
        rec.terminate()
        if midi:
            midi_chord_stop(*midi)
            print("\n[midi] chord released")

    d = db(peak_session)
    print(f"\n\nsession peak: {d:.1f} dBFS, clipped samples: {clipped}")
    if d > -1.0:
        print("-> TOO HOT: back off the Focusrite output (or ALSA 'Line' capture)")
    elif d < -30.0:
        print("-> too quiet: raise the Focusrite output toward peaks ~ -6 dBFS")
    else:
        print("-> in range (target ~ -6 dBFS peak)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
