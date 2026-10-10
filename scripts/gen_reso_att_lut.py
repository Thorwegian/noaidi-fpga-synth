#!/usr/bin/python3
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
# reso_att_lut: resonance-indexed INPUT attenuation for the dual
# (24 dB/oct) SVF. The 4-pole cascade's resonant peak grows ~Q^2, so at
# high resonance a full-scale input overdrives the internal +-8 (Q4.14)
# sat_q414 guardrail and clips harshly. Pre-filter attenuation, indexed by
# the log2 resonance code, scales the oscillator down so the cascade stays
# under its guardrail (cascade peak <= PEAK_LIMIT). The curve is
# ear-approved. Single (12 dB/oct) never overdrives ->
# unity, gated in RTL. 64 entries indexed by eff_reso[13:8], UQ0.16.
from pathlib import Path
import math
STATE_FRAC_BITS=28; COEF_FRAC_BITS=16; FS=96000.0
WORD36=1<<36; HALF36=1<<35
def wrap36(x): return ((x+HALF36)&(WORD36-1))-HALF36
STATE_CLAMP=96<<STATE_FRAC_BITS
def clamp_state(x): return STATE_CLAMP-1 if x>STATE_CLAMP-1 else (-STATE_CLAMP if x<-STATE_CLAMP else x)
RECIP_LUT=[round((1.0/(1.0+(i+0.5)/256))*(1<<COEF_FRAC_BITS)) for i in range(256)]
def recip(D): return RECIP_LUT[min((D&0xFFFF)*256>>COEF_FRAC_BITS,255)]
Q4_14_MAX=(1<<17)-1
def sat_q4_14(x):
    s=x>>14
    return Q4_14_MAX if s>Q4_14_MAX else (-(1<<17) if s<-(1<<17) else s)
def tpt_coeffs(fc,q1_16):
    g=math.pi*fc/FS; g28=round(g*(1<<STATE_FRAC_BITS)); g16=g28>>(STATE_FRAC_BITS-COEF_FRAC_BITS)
    D=(1<<COEF_FRAC_BITS)+((g16*g16)>>COEF_FRAC_BITS)+((q1_16*g16)>>COEF_FRAC_BITS)
    return g28, g28+(q1_16<<(STATE_FRAC_BITS-COEF_FRAC_BITS)), recip(D)
class SvfSection:
    __slots__=("s1","s2")
    def __init__(self): self.s1=0; self.s2=0
    def step(self,u,g,gR2,h):
        ms1=wrap36((self.s1*gR2)>>STATE_FRAC_BITS); t=wrap36(u-ms1-self.s2)
        yhp=wrap36((h*t)>>COEF_FRAC_BITS); gyhp=wrap36((g*yhp)>>STATE_FRAC_BITS)
        ybp=wrap36(gyhp+self.s1); s1n=clamp_state(wrap36(ybp+gyhp))
        gybp=wrap36((g*ybp)>>STATE_FRAC_BITS); ylp=wrap36(gybp+self.s2); s2n=clamp_state(wrap36(ylp+gybp))
        self.s1=s1n; self.s2=s2n; return ylp
def q1_from_eff(eff):
    octave=(eff>>10)&0xF; frac=(eff>>6)&0xF
    mantissa=round(math.sqrt(2)*2**(-frac/16)*(1<<COEF_FRAC_BITS))
    return mantissa>>octave
def cascade_peak(q1_16):
    if q1_16<=0: q1_16=1
    g,gR2,h=tpt_coeffs(1200.0,q1_16); sec1=SvfSection(); sec2=SvfSection()
    phase=0.0; phase_inc=110.0/FS; peak=0.0
    for i in range(int(0.2*FS)):
        phase=(phase+phase_inc)%1.0; u=round((2*phase-1.0)*(1<<STATE_FRAC_BITS))
        y1=sat_q4_14(sec1.step(u,g,gR2,h))
        a=abs(sec2.step(y1<<14,g,gR2,h))/(1<<STATE_FRAC_BITS)
        if a>peak: peak=a
    return peak
PEAK_LIMIT=5.5; N=64
out=Path(__file__).resolve().parent/"../rtl/dsp/reso_att_lut.hex"
with open(out,"w") as f:
    for i in range(N):
        eff=min((i<<8)+128,0x3FFF)
        raw=cascade_peak(q1_from_eff(eff))
        a=min(1.0,PEAK_LIMIT/max(raw,1e-9))
        f.write(f"{min(65535,round(a*65535)):04x}\n")
print(f"wrote {out} ({N} x UQ0.16)")
