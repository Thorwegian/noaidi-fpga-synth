#!/usr/bin/env python3
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
"""#97 faithful repro: BRIGHT resonant patch + repeated CHORDS (Thor's
actual test conditions). A chord fires a burst of voice allocations;
if the desync drops a voice's cutoff, that chord loses its high-band
energy. Measures per-chord high-band (>2.5 kHz) energy and flags the
dark chords.

    Copyright © 2026 Thor H. Linløkken <thj@thj.no>
    License: CERN-OHL-S v2
 
 """
import subprocess, sys, time, wave
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC
RATE = 48000
CHORD = [60, 64, 67, 71]   # Cmaj7, 4 voices
ROUNDS = 30

def cap():
    subprocess.run(["arecord","-D","hw:1,0","-f","S16_LE","-r",str(RATE),
                    "-c","2","-t","wav","-q","-d","1","/tmp/cg.wav"],capture_output=True)
    w=wave.open("/tmp/cg.wav"); d=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16); w.close()
    x=d.reshape(-1,2)[:,0].astype(np.float64)/32768.0
    n=8192; f=x[3000:]
    fr=f[:len(f)//n*n].reshape(-1,n)*np.hanning(n)
    sp=(np.abs(np.fft.rfft(fr,axis=1))**2).mean(axis=0); frq=np.fft.rfftfreq(n,1/RATE)
    tot=sp.sum()+1e-12; hi=sp[frq>2500].sum()
    rms=20*np.log10(max(np.sqrt((x**2).mean()),1e-12))
    return rms, 10*np.log10(max(hi,1e-20)), 100*hi/tot

def main():
    btctl=subprocess.Popen(["bluetoothctl"],stdin=subprocess.PIPE,
                           stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,text=True)
    try:
        bt(f"connect {NOAIDI_MAC}",btctl)
        if not wait_for_alsa_port(): print("FAIL: no BLE port"); return 2
        cl,port=open_midi_out()
        from alsa_midi import NoteOnEvent,NoteOffEvent,ControlChangeEvent
        def cc(n,v): cl.event_output(ControlChangeEvent(channel=0,param=n,value=v),port=port); cl.drain_output()
        # BRIGHT resonant test patch (not default): open cutoff + resonance
        cc(7,100); cc(74,115); cc(106,0); cc(71,35); cc(87,0); cc(30,127); cc(120,0)
        time.sleep(0.3)
        rows=[]
        for i in range(ROUNDS):
            for n in CHORD:
                cl.event_output(NoteOnEvent(note=n,channel=0,velocity=100),port=port)
            cl.drain_output(); time.sleep(0.15)
            rms,hidb,hifrac=cap()
            for n in CHORD:
                cl.event_output(NoteOffEvent(note=n,channel=0,velocity=0),port=port)
            cl.drain_output(); cc(120,0); time.sleep(0.15)
            rows.append((i,rms,hidb,hifrac))
        cc(74,64); cc(87,64); cc(71,4); cl.close()
        hidb=np.array([h for _,_,h,_ in rows]); med=np.median(hidb)
        print(f"median high-band energy {med:+.1f} dB")
        print("dark chords (high-band > 3 dB below median = a voice dropped its cutoff):")
        n_dark=0
        for i,rms,h,fr in rows:
            mark = " <-- DARK" if h < med-3 else ""
            if mark: n_dark+=1
            print(f"  chord #{i:2d}: RMS {rms:+.1f}  high-band {h:+.1f} dB ({fr:4.1f}%){mark}")
        print(f"DARK chords: {n_dark}/{ROUNDS}")
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
