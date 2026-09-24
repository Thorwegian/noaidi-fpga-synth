#!/usr/bin/env python3
"""
    Copyright © 2026 Thor H. Linløkken <thj@thj.no>
    License: CERN-OHL-S v2

Do BLE note-ons reach the firmware AND produce audio? Mark the
console, hold a note, capture during the hold, then the caller greps
the console for what the firmware saw."""
import subprocess, sys, time, wave
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ble_midi_fuzz import bt, wait_for_alsa_port, open_midi_out, NOAIDI_MAC
RATE=48000
btctl=subprocess.Popen(["bluetoothctl"],stdin=subprocess.PIPE,
                       stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,text=True)
try:
    bt(f"connect {NOAIDI_MAC}",btctl)
    if not wait_for_alsa_port(): print("FAIL: no BLE port"); raise SystemExit(2)
    cl,port=open_midi_out()
    from alsa_midi import NoteOnEvent,NoteOffEvent,ControlChangeEvent
    def cc(n,v): cl.event_output(ControlChangeEvent(channel=0,param=n,value=v),port=port); cl.drain_output()
    print("MARK", time.time())
    cc(7,100); cc(120,0); time.sleep(0.2)          # ensure volume up, clear mute
    cl.event_output(NoteOnEvent(note=60,channel=0,velocity=110),port=port); cl.drain_output()
    cl.event_output(NoteOnEvent(note=64,channel=0,velocity=110),port=port); cl.drain_output()
    cl.event_output(NoteOnEvent(note=67,channel=0,velocity=110),port=port); cl.drain_output()
    time.sleep(0.4)
    subprocess.run(["arecord","-D","hw:1,0","-f","S16_LE","-r",str(RATE),
                    "-c","2","-t","wav","-q","-d","2","/tmp/np.wav"],capture_output=True)
    for n in (60,64,67):
        cl.event_output(NoteOffEvent(note=n,channel=0,velocity=0),port=port); cl.drain_output()
    cl.close()
    w=wave.open("/tmp/np.wav"); d=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16); w.close()
    x=d.reshape(-1,2)[:,0].astype(np.float64)/32768.0
    rms=20*np.log10(max(np.sqrt((x**2).mean()),1e-12))
    print(f"AUDIO during held C-major chord: RMS {rms:+.1f} dBFS  peak {20*np.log10(max(np.abs(d).max()/32768,1e-12)):+.1f}")
finally:
    try:
        bt(f"disconnect {NOAIDI_MAC}",btctl); time.sleep(1.5)
        bt(f"untrust {NOAIDI_MAC}",btctl); time.sleep(0.5); btctl.stdin.close()
    except Exception: pass
    btctl.terminate()
    subprocess.run(["bluetoothctl","disconnect",NOAIDI_MAC],capture_output=True,timeout=10)
    subprocess.run(["bluetoothctl","untrust",NOAIDI_MAC],capture_output=True,timeout=10)
