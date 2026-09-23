#!/usr/bin/env python3
"""Reproduce Thor's 'blaaarph...silence...blaaarph'. Idle first (is it a
drone with no keys?), then continuous chord play at his likely patch
(bright + resonant), recording a continuous stream and reporting the
per-50ms RMS envelope (bursts vs silence) and spectral character."""
import subprocess, sys, time, wave, threading
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC
RATE=48000; CH=[60,64,67,71]

def envelope(path, label):
    w=wave.open(path); d=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16); w.close()
    x=d.reshape(-1,2)[:,0].astype(np.float64)/32768.0
    win=RATE//20  # 50 ms
    env=[]
    for i in range(0,len(x)-win,win):
        seg=x[i:i+win]; env.append(20*np.log10(max(np.sqrt((seg**2).mean()),1e-12)))
    env=np.array(env)
    print(f"[{label}] {len(env)} x 50ms frames; RMS min {env.min():+.0f} max {env.max():+.0f} dBFS")
    # ascii envelope
    s=""
    for e in env:
        s += "#" if e>-20 else ("+" if e>-40 else ("." if e>-70 else " "))
    print(f"[{label}] env: |{s}|  (#>-20  +>-40  .>-70  ' 'silent)")
    # spectrum of the loudest frame
    lo=int(np.argmax(env))*win
    seg=x[lo:lo+16384]
    if len(seg)>=4096:
        n=4096; fr=seg[:len(seg)//n*n].reshape(-1,n)*np.hanning(n)
        sp=np.abs(np.fft.rfft(fr,axis=1)).mean(axis=0); frq=np.fft.rfftfreq(n,1/RATE)
        cen=(frq*sp).sum()/(sp.sum()+1e-12)
        top=np.argsort(sp[1:])[::-1][:4]+1
        print(f"[{label}] loud frame centroid {cen:.0f} Hz; peaks: " +
              ", ".join(f"{frq[b]:.0f}Hz" for b in top))

def main():
    btctl=subprocess.Popen(["bluetoothctl"],stdin=subprocess.PIPE,
                           stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,text=True)
    try:
        bt(f"connect {NOAIDI_MAC}",btctl)
        if not wait_for_alsa_port(): print("FAIL: no BLE"); return 2
        cl,port=open_midi_out()
        from alsa_midi import NoteOnEvent,NoteOffEvent,ControlChangeEvent
        def cc(n,v): cl.event_output(ControlChangeEvent(channel=0,param=n,value=v),port=port); cl.drain_output()
        cc(120,0); time.sleep(0.5)
        print("=== IDLE (no keys) ===")
        subprocess.run(["arecord","-D","hw:1,0","-f","S16_LE","-r",str(RATE),"-c","2",
                        "-t","wav","-q","-d","5","/tmp/bl_idle.wav"],capture_output=True)
        envelope("/tmp/bl_idle.wav","idle")

        print("=== CONTINUOUS CHORDS, bright + HIGH resonance ===")
        cc(7,100); cc(74,110); cc(71,95); cc(87,0); cc(30,127); time.sleep(0.2)
        stop=threading.Event()
        def player():
            i=0
            while not stop.is_set():
                for n in CH:
                    cl.event_output(NoteOnEvent(note=n+ (i%3)*0,channel=0,velocity=100),port=port)
                cl.drain_output(); time.sleep(0.18)
                for n in CH:
                    cl.event_output(NoteOffEvent(note=n,channel=0,velocity=0),port=port)
                cl.drain_output(); time.sleep(0.06); i+=1
        th=threading.Thread(target=player); th.start()
        time.sleep(0.3)
        subprocess.run(["arecord","-D","hw:1,0","-f","S16_LE","-r",str(RATE),"-c","2",
                        "-t","wav","-q","-d","10","/tmp/bl_play.wav"],capture_output=True)
        stop.set(); th.join()
        cc(120,0); cc(74,64); cc(71,4); cc(87,64); cl.close()
        envelope("/tmp/bl_play.wav","play")
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
