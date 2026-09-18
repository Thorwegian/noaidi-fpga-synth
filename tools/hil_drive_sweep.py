#!/usr/bin/env python3
"""Is the bad corner CLIPPING at all? (#125)

The -12.4 dB IMD at cutoff CC74=64 / reso 127 survived widening the pole
output word from +-8 to +-128 with its LEVEL unchanged, so sat_q414 is not
what limits it. Before guessing at another node, settle the category:

    clipping     -> distortion is LEVEL-DEPENDENT. Drop the drive and the
                    IMD must fall, because the signal stops reaching
                    whatever rail it was hitting.
    structural   -> IMD is FLAT vs drive. Then it is not a rail at all but
                    something scale-free: coefficient quantisation, the
                    recip LUT, the state clamp, or the metric itself
                    counting resonant ring as "non-harmonic".

Same patch and metric as tools/hil_filter_imd.py, but the grid is drive
level at the ONE corner that reproduces (five runs, +-0.1 dB). Also runs
12 dB/oct for contrast: Thor reports 24 dB/oct is far easier to overdrive,
so a single pole should sit lower if this is the cascade's doing.
"""
import subprocess
import sys
import time

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from hil_filter_imd import (PATCH, NOTES, capture, spectrum, analyse,
                            AUDIO_DEV, RATE)
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC

CUTOFF, RESO = 64, 127          # the reproducible corner
VOLUMES = [127, 110, 96, 80, 64, 48]     # CC7, ~ -0.4 dB per step region


def main():
    print(f"[corner] cutoff CC74={CUTOFF}, reso CC71={RESO} "
          f"(reproduces to +-0.1 dB over 5 runs)")
    print("[test]   IMD vs drive. Falls with level => clipping. "
          "Flat => structural, not a rail.")
    btctl = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True)
    try:
        bt(f"connect {NOAIDI_MAC}", btctl)
        if not wait_for_alsa_port():
            print("FAIL: BLE ALSA port never appeared")
            return 2
        client, port = open_midi_out()
        from alsa_midi import NoteOnEvent, NoteOffEvent, ControlChangeEvent

        def send(ev):
            client.event_output(ev, port=port)
            client.drain_output()

        def cc(n, v):
            send(ControlChangeEvent(channel=0, param=n, value=v))

        for n, v in PATCH:
            cc(n, v)
            time.sleep(0.03)
        time.sleep(0.2)
        cc(120, 0)
        time.sleep(0.5)
        _, noise_non, _ = spectrum(capture(1.0))

        for slope, sval in (("24 dB/oct", 127), ("12 dB/oct", 0)):
            cc(30, sval)
            time.sleep(0.2)
            print(f"\n  === {slope} ===")
            print("   CC7  peak dBFS    IMD dB")
            base = None
            for vol in VOLUMES:
                cc(7, vol); cc(74, CUTOFF); cc(71, RESO)
                time.sleep(0.15)
                for n in NOTES:
                    send(NoteOnEvent(note=n, channel=0, velocity=100))
                time.sleep(0.5)
                x = capture(1.0)
                for n in NOTES:
                    send(NoteOffEvent(note=n, channel=0, velocity=0))
                cc(120, 0)
                time.sleep(0.3)
                if x is None or len(x) < 4096 or np.abs(x).max() == 0:
                    print(f"   {vol:4d}   RIG SILENT -- aborting")
                    raise SystemExit(4)
                imd, pk, ok = analyse(x, noise_non)
                if base is None:
                    base = (pk, imd)
                d_lvl = pk - base[0]
                d_imd = imd - base[1]
                flag = "" if ok else "  (too quiet to trust)"
                print(f"   {vol:4d}  {pk:7.1f}   {imd:+7.1f}   "
                      f"[level {d_lvl:+5.1f} dB, IMD {d_imd:+5.1f} dB]{flag}")
        cc(7, 127); cc(71, 4); cc(30, 127); cc(74, 64)
        client.close()
    finally:
        try:
            bt(f"disconnect {NOAIDI_MAC}", btctl)
            time.sleep(1.5)
            bt(f"untrust {NOAIDI_MAC}", btctl)
            btctl.stdin.close()
        except Exception:
            pass
        btctl.terminate()
        subprocess.run(["bluetoothctl", "disconnect", NOAIDI_MAC],
                       capture_output=True, timeout=10)
        subprocess.run(["bluetoothctl", "untrust", NOAIDI_MAC],
                       capture_output=True, timeout=10)
        print("[ble] disconnected + untrusted (cleanup)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
