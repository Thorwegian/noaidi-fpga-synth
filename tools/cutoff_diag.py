#!/usr/bin/env python3
"""
    Copyright © 2026 Thor H. Linløkken <thj@thj.no>
    License: CERN-OHL-S v2
 
Robust cutoff diagnosis: prove sound is present (RMS) and track the
spectral CENTROID (Hz) as a cutoff proxy across a CC 74 sweep, with a
velocity control to match Thor's 'only velocity works' observation."""
import subprocess, sys, time, wave
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC

AUDIO_DEV, RATE, NOTE = "hw:1,0", 48000, 57

def cap(secs=1):
    subprocess.run(["arecord","-D",AUDIO_DEV,"-f","S16_LE","-r",str(RATE),
                    "-c","2","-t","wav","-q","-d",str(secs),"/tmp/cd.wav"],
                   capture_output=True)
    w=wave.open("/tmp/cd.wav"); d=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16); w.close()
    return d.reshape(-1,2)[:,0].astype(np.float64)/32768.0

def stats(x):
    rms = 20*np.log10(max(np.sqrt((x**2).mean()),1e-12))
    n=8192; f=x[RATE//4:]
    if len(f)<n: return rms, float('nan')
    fr=f[:len(f)//n*n].reshape(-1,n)*np.hanning(n)
    sp=np.abs(np.fft.rfft(fr,axis=1)).mean(axis=0); frq=np.fft.rfftfreq(n,1/RATE)
    centroid = (frq*sp).sum()/(sp.sum()+1e-12)
    return rms, centroid

def main():
    btctl=subprocess.Popen(["bluetoothctl"],stdin=subprocess.PIPE,
                           stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,text=True)
    try:
        bt(f"connect {NOAIDI_MAC}",btctl)
        if not wait_for_alsa_port(): print("FAIL: no BLE port"); return 2
        cl,port=open_midi_out()
        from alsa_midi import NoteOnEvent,NoteOffEvent,ControlChangeEvent
        def cc(n,v): cl.event_output(ControlChangeEvent(channel=0,param=n,value=v),port=port); cl.drain_output()
        def measure(vel=100):
            cl.event_output(NoteOnEvent(note=NOTE,channel=0,velocity=vel),port=port); cl.drain_output()
            time.sleep(0.3); r,c=stats(cap(1))
            cl.event_output(NoteOffEvent(note=NOTE,channel=0,velocity=0),port=port); cl.drain_output()
            cc(120,0); time.sleep(0.3); return r,c

        print("--- baseline: default patch, one note (proves sound path) ---")
        cc(120,0); time.sleep(0.2)
        r,c=measure(); print(f"  default note: RMS {r:+.1f} dBFS  centroid {c:7.0f} Hz")

        print("--- CC74 sweep, velocity->cutoff OFF (CC87=0): isolates CC74 ---")
        cc(87,0); cc(71,10); time.sleep(0.1)
        for v in (5,40,80,127):
            cc(74,v); time.sleep(0.15)
            r,c=measure(vel=100); print(f"  CC74={v:3d}: RMS {r:+.1f} dBFS  centroid {c:7.0f} Hz")

        print("--- velocity control (CC87=64 default), CC74 fixed mid ---")
        cc(87,64); cc(74,40); time.sleep(0.15)
        for vel in (20,110):
            r,c=measure(vel=vel); print(f"  vel={vel:3d}: RMS {r:+.1f} dBFS  centroid {c:7.0f} Hz")

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
