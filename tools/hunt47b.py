#!/usr/bin/env python3
"""#97 hunt round 2: element + producer read-back, SWAP-FREE. Each CC 118
reads the active bank; play chords with CC churn between calls so the
engine keeps swapping and both banks get sampled across the calls."""
import subprocess, sys, time
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC
CHORD = [60, 64, 67, 71]

def main():
    btctl=subprocess.Popen(["bluetoothctl"],stdin=subprocess.PIPE,
                           stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,text=True)
    try:
        bt(f"connect {NOAIDI_MAC}",btctl)
        if not wait_for_alsa_port(): print("FAIL: no BLE"); return 2
        cl,port=open_midi_out()
        from alsa_midi import NoteOnEvent,NoteOffEvent,ControlChangeEvent
        def cc(n,v): cl.event_output(ControlChangeEvent(channel=0,param=n,value=v),port=port); cl.drain_output()
        cc(7,100); cc(74,115); cc(71,35); cc(87,0); cc(30,127); time.sleep(0.3)
        for rnd in range(8):
            print(f"ROUND {rnd}: chords + CC churn, then verify (active bank)")
            for i in range(6):
                for n in CHORD:
                    cl.event_output(NoteOnEvent(note=n,channel=0,velocity=100),port=port)
                cl.drain_output(); time.sleep(0.1)
                cc(74, 90 if i&1 else 115)   # churn -> forces config swaps
                for n in CHORD:
                    cl.event_output(NoteOffEvent(note=n,channel=0,velocity=0),port=port)
                cl.drain_output(); cc(120,0); time.sleep(0.05)
            cc(118,127); time.sleep(1.0)     # verify reads whatever bank is active
        cc(74,64); cc(87,64); cc(71,4); cl.close()
    finally:
        try:
            bt(f"disconnect {NOAIDI_MAC}",btctl); time.sleep(1.5)
            bt(f"untrust {NOAIDI_MAC}",btctl); time.sleep(0.5); btctl.stdin.close()
        except Exception: pass
        btctl.terminate()
        subprocess.run(["bluetoothctl","disconnect",NOAIDI_MAC],capture_output=True,timeout=10)
        subprocess.run(["bluetoothctl","untrust",NOAIDI_MAC],capture_output=True,timeout=10)
    return 0
if __name__=="__main__": raise SystemExit(main())
