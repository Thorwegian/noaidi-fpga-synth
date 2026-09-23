#!/usr/bin/env python3
"""Record ONE default-patch chord (full attack+sustain) to a WAV for
Thor to confirm, plus a sanity note with the filter opened. No patch
controls changed for the chord (Thor's condition)."""
import subprocess, sys, time, wave
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC
RATE=48000; CH=[60,64,67,71]

def stats(path):
    w=wave.open(path); d=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16); w.close()
    x=d.reshape(-1,2)[:,0].astype(np.float64)/32768.0
    peak=20*np.log10(max(np.abs(x).max(),1e-12))
    # attack peak = loudest 10ms in first 200ms
    aw=RATE//100; a=x[:RATE//5]
    ap=max((np.abs(a[i:i+aw]).max() for i in range(0,len(a)-aw,aw)), default=0)
    rms=20*np.log10(max(np.sqrt((x**2).mean()),1e-12))
    print(f"  peak {peak:+.1f} dBFS  attackpeak {20*np.log10(max(ap,1e-12)):+.1f} dBFS  RMS {rms:+.1f} dBFS")

def main():
    btctl=subprocess.Popen(["bluetoothctl"],stdin=subprocess.PIPE,
                           stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,text=True)
    try:
        bt(f"connect {NOAIDI_MAC}",btctl)
        if not wait_for_alsa_port(): print("FAIL: no BLE"); return 2
        cl,port=open_midi_out()
        from alsa_midi import NoteOnEvent,NoteOffEvent,ControlChangeEvent
        def cc(n,v): cl.event_output(ControlChangeEvent(channel=0,param=n,value=v),port=port); cl.drain_output()
        def chord(on):
            for n in CH:
                cl.event_output((NoteOnEvent if on else NoteOffEvent)(note=n,channel=0,velocity=100 if on else 0),port=port)
            cl.drain_output()
        cc(120,0); time.sleep(0.3)
        print("=== default-patch chord (Thor's condition, nothing touched) ===")
        chord(True)
        subprocess.run(["arecord","-D","hw:1,0","-f","S16_LE","-r",str(RATE),"-c","2",
                        "-t","wav","-q","-d","2","/tmp/chord_default.wav"],capture_output=True)
        chord(False); cc(120,0); time.sleep(0.5)
        stats("/tmp/chord_default.wav")
        print("=== SANITY: same chord, filter opened (CC74=100) ===")
        cc(74,100); time.sleep(0.1); chord(True)
        subprocess.run(["arecord","-D","hw:1,0","-f","S16_LE","-r",str(RATE),"-c","2",
                        "-t","wav","-q","-d","2","/tmp/chord_open.wav"],capture_output=True)
        chord(False); cc(120,0); cc(74,64); time.sleep(0.3)
        stats("/tmp/chord_open.wav")
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
