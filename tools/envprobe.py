#!/usr/bin/env python3
"""Hold a chord 3s under conditions to isolate WHY it cuts off:
 a) default (nothing touched)
 b) MOD-env -> cutoff OFF (CC107=64): if it now sustains, the filter
    envelope was closing the filter
 c) filter opened (CC74=110): if it sustains, low base cutoff
 d) amp sustain max (CC79=127): if THIS is what fixes it, it's the amp
    envelope, not the filter."""
import subprocess, sys, time, wave
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC
RATE=48000; CH=[60,64,67,71]

def main():
    b=subprocess.Popen(["bluetoothctl"],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,text=True)
    try:
        bt(f"connect {NOAIDI_MAC}",b)
        if not wait_for_alsa_port(): print("FAIL: no BLE"); return 2
        cl,port=open_midi_out()
        from alsa_midi import NoteOnEvent,NoteOffEvent,ControlChangeEvent
        def cc(n,v): cl.event_output(ControlChangeEvent(channel=0,param=n,value=v),port=port); cl.drain_output()
        def hold_measure(label):
            cc(120,0); time.sleep(0.3)
            for n in CH: cl.event_output(NoteOnEvent(note=n,channel=0,velocity=100),port=port)
            cl.drain_output()
            subprocess.run(["arecord","-D","hw:1,0","-f","S16_LE","-r",str(RATE),"-c","2","-t","wav","-q","-d","3","/tmp/ep.wav"],capture_output=True)
            for n in CH: cl.event_output(NoteOffEvent(note=n,channel=0,velocity=0),port=port)
            cl.drain_output()
            w=wave.open("/tmp/ep.wav"); d=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16); w.close()
            x=d.reshape(-1,2)[:,0].astype(np.float64)/32768.0
            win=RATE//4
            env=[20*np.log10(max(np.sqrt((x[i:i+win]**2).mean()),1e-12)) for i in range(0,len(x)-win,win)]
            print(f"  {label:22s} 250ms env dBFS: "+" ".join(f"{e:+.0f}" for e in env)+
                  ("   <-- CUTS OFF" if env[-1] < env[0]-25 else "   sustains"))
        print("=== hold-chord envelope (per 250 ms), fix build ===")
        hold_measure("a) default")
        cc(107,64); hold_measure("b) MOD->cutoff OFF"); cc(107,87)
        cc(74,110); hold_measure("c) filter open CC74=110"); cc(74,64)
        cc(79,127); hold_measure("d) amp sustain max"); cc(79,120)
        cl.close()
    finally:
        try:
            bt(f"disconnect {NOAIDI_MAC}",b); time.sleep(1.2); bt(f"untrust {NOAIDI_MAC}",b); time.sleep(0.4); b.stdin.close()
        except Exception: pass
        b.terminate()
        subprocess.run(["bluetoothctl","disconnect",NOAIDI_MAC],capture_output=True,timeout=10)
        subprocess.run(["bluetoothctl","untrust",NOAIDI_MAC],capture_output=True,timeout=10)
    return 0
if __name__=="__main__": raise SystemExit(main())
