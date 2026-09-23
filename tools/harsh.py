#!/usr/bin/env python3
"""Discrete chords (attack, hold, release, gap) like Thor plays. Per
chord: level, centroid, and HARSHNESS = fraction of energy above 8 kHz
(aliasing / buzz / self-osc = high). A 'blaaarph' chord reads harsh."""
import subprocess, sys, time, wave
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC
RATE=48000; CH=[60,64,67,71]

def rec(path,secs):
    subprocess.run(["arecord","-D","hw:1,0","-f","S16_LE","-r",str(RATE),"-c","2",
                    "-t","wav","-q","-d",str(secs),path],capture_output=True)
    w=wave.open(path); d=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16); w.close()
    return d.reshape(-1,2)[:,0].astype(np.float64)/32768.0

def analyse(x,label):
    rms=20*np.log10(max(np.sqrt((x**2).mean()),1e-12))
    n=8192; f=x[2000:]
    if len(f)<n: print(f"  {label}: too short"); return
    fr=f[:len(f)//n*n].reshape(-1,n)*np.hanning(n)
    sp=(np.abs(np.fft.rfft(fr,axis=1))**2).mean(axis=0); frq=np.fft.rfftfreq(n,1/RATE)
    tot=sp.sum()+1e-12
    cen=(frq*sp).sum()/tot
    harsh=100*sp[frq>8000].sum()/tot
    print(f"  {label}: RMS {rms:+.1f} dBFS  centroid {cen:5.0f} Hz  harsh(>8k) {harsh:4.1f}%")

def main():
    btctl=subprocess.Popen(["bluetoothctl"],stdin=subprocess.PIPE,
                           stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,text=True)
    try:
        bt(f"connect {NOAIDI_MAC}",btctl)
        if not wait_for_alsa_port(): print("FAIL: no BLE"); return 2
        cl,port=open_midi_out()
        from alsa_midi import NoteOnEvent,NoteOffEvent,ControlChangeEvent
        def cc(n,v): cl.event_output(ControlChangeEvent(channel=0,param=n,value=v),port=port); cl.drain_output()
        cc(120,0); time.sleep(0.3)
        print("=== DEFAULT patch, 8 discrete chords (attack captured) ===")
        for i in range(8):
            for n in CH:
                cl.event_output(NoteOnEvent(note=n,channel=0,velocity=100),port=port)
            cl.drain_output()
            time.sleep(0.05)                 # capture the ATTACK
            x=rec("/tmp/h.wav",1)
            for n in CH:
                cl.event_output(NoteOffEvent(note=n,channel=0,velocity=0),port=port)
            cl.drain_output(); cc(120,0); time.sleep(0.4)   # silence gap
            analyse(x,f"chord {i}")
        cl.close()
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
