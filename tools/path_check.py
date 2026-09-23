#!/usr/bin/env python3
"""Is the capture path still bit-perfect digital? Check the mixer
source, capture silence (digital = only the DC residual, no floor),
and the CC119 tone (exact on bin 32, off-bins at true zero)."""
import subprocess, sys, time, wave
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC
RATE=48000

def src():
    r=subprocess.run(["amixer","-c","1","cget","numid=16"],capture_output=True,text=True)
    for l in r.stdout.splitlines():
        if l.strip().startswith(": values="): return l.strip()
    return "?"

def rec(path,secs=1):
    subprocess.run(["arecord","-D","hw:1,0","-f","S16_LE","-r",str(RATE),"-c","2",
                    "-t","wav","-q","-d",str(secs),path],capture_output=True)
    w=wave.open(path); d=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16); w.close()
    return d.reshape(-1,2)

def db(x): return 20*np.log10(max(float(x),1e-12))

def main():
    print("capture source numid=16", src(), " (item 1=Line, 2=IEC958 In)")
    btctl=subprocess.Popen(["bluetoothctl"],stdin=subprocess.PIPE,
                           stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,text=True)
    try:
        bt(f"connect {NOAIDI_MAC}",btctl)
        if not wait_for_alsa_port(): print("FAIL: no BLE"); return 2
        cl,port=open_midi_out()
        from alsa_midi import ControlChangeEvent
        def cc(n,v): cl.event_output(ControlChangeEvent(channel=0,param=n,value=v),port=port); cl.drain_output()
        cc(119,0); time.sleep(0.4)
        d=rec("/tmp/pc_sil.wav"); st=d.astype(np.float64)/32768.0
        print(f"[silence] nonzero samples {int(np.count_nonzero(d))}/{d.size}  "
              f"distinct L values {len(np.unique(d[:,0]))}  peak {db(np.abs(st).max()):+.1f} dBFS")
        cc(119,127); time.sleep(0.5)
        d=rec("/tmp/pc_tone.wav"); L=d[:,0].astype(np.float64)/32768.0
        n=1024; fr=L[12000:12000+n*32].reshape(-1,n)
        sp=np.abs(np.fft.rfft(fr,axis=1)).mean(axis=0)/512
        pk=int(np.argmax(sp[1:])+1)
        mask=np.ones(len(sp),bool); mask[0]=False
        for h in range(1,8):
            b=32*h
            if b<len(sp): mask[max(b-2,0):b+3]=False
        print(f"[tone] peak bin {pk} ({pk*RATE/n:.0f} Hz) {db(sp[pk]):+.1f} dBFS; "
              f"median off-bin {db(np.median(sp[mask])):+.1f} dBFS")
        cc(119,0); cl.close()
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
