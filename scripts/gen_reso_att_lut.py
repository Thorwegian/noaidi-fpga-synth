#!/usr/bin/python3
# reso_att_lut (#43): resonance-indexed INPUT attenuation for the dual
# (24 dB/oct) SVF. The 4-pole cascade's resonant peak grows ~Q^2, so at
# high resonance a full-scale input overdrives the internal +-8 (Q4.14)
# sat_q414 guardrail and clips harshly. Pre-filter attenuation, indexed by
# the log2 resonance code, scales the oscillator down so the cascade stays
# under its guardrail (raw pole2 <= RAW_TARGET). Ear-approved curve
# (gain_sweep_combo, 2026-09-17). Single (12 dB/oct) never overdrives ->
# unity, gated in RTL. 64 entries indexed by eff_reso[13:8], UQ0.16.
from pathlib import Path
import math
SF=28; CF=16; FS=96000.0
W36=1<<36; H36=1<<35
def w36(x): return ((x+H36)&(W36-1))-H36
CLAMP=96<<SF
def scl(x): return CLAMP-1 if x>CLAMP-1 else (-CLAMP if x<-CLAMP else x)
RLUT=[round((1.0/(1.0+(i+0.5)/256))*(1<<CF)) for i in range(256)]
def recip(D): return RLUT[min((D&0xFFFF)*256>>CF,255)]
Q414=(1<<17)-1
def sat414(x):
    s=x>>14
    return Q414 if s>Q414 else (-(1<<17) if s<-(1<<17) else s)
def base(fc,q1_16):
    g=math.pi*fc/FS; g28=round(g*(1<<SF)); g16=g28>>(SF-CF)
    D=(1<<CF)+((g16*g16)>>CF)+((q1_16*g16)>>CF)
    return g28, g28+(q1_16<<(SF-CF)), recip(D)
class Pole:
    __slots__=("s1","s2")
    def __init__(self): self.s1=0; self.s2=0
    def step(self,u,g,gR2,h):
        ms1=w36((self.s1*gR2)>>SF); t=w36(u-ms1-self.s2)
        yhp=w36((h*t)>>CF); gyhp=w36((g*yhp)>>SF)
        ybp=w36(gyhp+self.s1); s1n=scl(w36(ybp+gyhp))
        gybp=w36((g*ybp)>>SF); ylp=w36(gybp+self.s2); s2n=scl(w36(ylp+gybp))
        self.s1=s1n; self.s2=s2n; return ylp
def q1_from_eff(eff):
    octv=(eff>>10)&0xF; frac=(eff>>6)&0xF
    lj=round(math.sqrt(2)*2**(-frac/16)*(1<<CF))
    return lj>>octv
def raw_pole2(q1_16):
    if q1_16<=0: q1_16=1
    g,gR2,h=base(1200.0,q1_16); p1=Pole(); p2=Pole()
    ph=0.0; inc=110.0/FS; pk=0.0
    for i in range(int(0.2*FS)):
        ph=(ph+inc)%1.0; u=round((2*ph-1.0)*(1<<SF))
        f1=sat414(p1.step(u,g,gR2,h))
        a=abs(p2.step(f1<<14,g,gR2,h))/(1<<SF)
        if a>pk: pk=a
    return pk
RAW_TARGET=5.5; N=64
out=Path(__file__).resolve().parent/"../rtl/element/reso_att_lut.hex"
with open(out,"w") as f:
    for i in range(N):
        eff=min((i<<8)+128,0x3FFF)
        raw=raw_pole2(q1_from_eff(eff))
        a=min(1.0,RAW_TARGET/max(raw,1e-9))
        f.write(f"{min(65535,round(a*65535)):04x}\n")
print(f"wrote {out} ({N} x UQ0.16)")
