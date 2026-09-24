#!/usr/bin/env python3
"""
    Copyright © 2026 Thor H. Linløkken <thj@thj.no>
    License: CERN-OHL-S v2

#97 characterization: play one fixed pitch many times (mono, so the
allocator cycles the 32-voice pool) and measure each note's spectral
centroid. A voice whose cutoff config goes stale shows as a periodic
dark note (every 32nd). Prints the series and flags outliers + period."""
import subprocess, sys, time, wave
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC
RATE, NOTE, N = 48000, 57, 64

def cap_centroid(secs=1):
    subprocess.run(["arecord","-D","hw:1,0","-f","S16_LE","-r",str(RATE),
                    "-c","2","-t","wav","-q","-d",str(int(secs)),"/tmp/gh.wav"],capture_output=True)
    w=wave.open("/tmp/gh.wav"); d=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16); w.close()
    x=d.reshape(-1,2)[:,0].astype(np.float64)/32768.0
    rms=np.sqrt((x**2).mean())
    n=4096; f=x[2000:]
    if len(f)<n: return -120.0, 0.0
    fr=f[:len(f)//n*n].reshape(-1,n)*np.hanning(n)
    sp=np.abs(np.fft.rfft(fr,axis=1)).mean(axis=0); frq=np.fft.rfftfreq(n,1/RATE)
    c=(frq*sp).sum()/(sp.sum()+1e-12)
    return 20*np.log10(max(rms,1e-12)), c

def main():
    btctl=subprocess.Popen(["bluetoothctl"],stdin=subprocess.PIPE,
                           stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,text=True)
    try:
        bt(f"connect {NOAIDI_MAC}",btctl)
        if not wait_for_alsa_port(): print("FAIL: no BLE port"); return 2
        cl,port=open_midi_out()
        from alsa_midi import NoteOnEvent,NoteOffEvent,ControlChangeEvent
        def cc(n,v): cl.event_output(ControlChangeEvent(channel=0,param=n,value=v),port=port); cl.drain_output()
        cc(87,0); cc(74,90); cc(71,10); cc(120,0); time.sleep(0.3)   # vel->cut OFF, mid-bright cutoff
        rows=[]
        for i in range(N):
            cl.event_output(NoteOnEvent(note=NOTE,channel=0,velocity=100),port=port); cl.drain_output()
            time.sleep(0.15)
            r,c=cap_centroid(1)
            cl.event_output(NoteOffEvent(note=NOTE,channel=0,velocity=0),port=port); cl.drain_output()
            cc(120,0); time.sleep(0.12)
            rows.append((i,r,c))
        cc(74,64); cc(87,64); cc(71,4); cl.close()
        cents=np.array([c for _,_,c in rows])
        med=np.median(cents); mad=np.median(np.abs(cents-med))+1e-9
        print(f"median centroid {med:.0f} Hz")
        print("outliers (|centroid - median| > 4*MAD):")
        outs=[]
        for i,r,c in rows:
            if abs(c-med) > 4*mad:
                outs.append(i); print(f"  note #{i:3d} (voice {i%32:2d}): RMS {r:+.1f} dBFS  centroid {c:6.0f} Hz  <-- OFF")
        if outs:
            mods=sorted(set(o%32 for o in outs))
            print(f"outlier count {len(outs)}/{N}; voice-slots hit (idx mod 32): {mods}")
            diffs=np.diff(outs)
            print(f"gaps between outliers: {list(diffs)}")
        else:
            print("  none - no periodic dark note in this run")
        print("full series (idx:centroid):")
        print(" ".join(f"{i}:{int(c)}" for i,_,c in rows))
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
