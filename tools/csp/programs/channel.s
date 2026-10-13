; channel.s -- what each channel adds to every note: pitch and cutoff
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; After map.s and lfo.s. For each of the 16 channels (a vector loop):
;
;   CH_PITCH  = BEND + LFO 1 × LFO1_PITCH + LFO 2 × LFO2_PITCH
;   CH_CUTOFF = CUTOFF_BASE + LFO 1 × LFO1_CUTOFF + LFO 2 × LFO2_CUTOFF
;               + KEY_TRACK × CH_PITCH
;
; all in octaves. The LFOs are those the channel's LFO1 and LFO2 fields
; point at in the pool. The voices add their own note (voice.s).

        IDX     i, =#CHANNELS, 0
        LOOP.vi channels, =#16, =#64
        IDX     j, [i+LFO1], 0                      ; j → LFO 1's record
        MAC     [i+TP], 0, [j+OUT], [i+LFO1_PITCH]
        MAC     [i+TC], 0, [j+OUT], [i+LFO1_CUTOFF]
        IDX     j, [i+LFO2], 0
        MAC     [i+TP], [i+TP], [j+OUT], [i+LFO2_PITCH]
        MAC     [i+TC], [i+TC], [j+OUT], [i+LFO2_CUTOFF]
        ADD3    [i+CH_PITCH], 0, [i+TP], [i+BEND]
        MAC     [i+TC], [i+TC], [i+CH_PITCH], [i+KEY_TRACK]
        ADD3    [i+CH_CUTOFF], 0, [i+TC], [i+CUTOFF_BASE]
channels:
