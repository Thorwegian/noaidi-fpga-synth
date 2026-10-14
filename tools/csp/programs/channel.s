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
; point at in the pool. The voices add their own note (voice.s). The same
; LFOs move the pulse width and the resonance, which go straight to the
; channel's sinks (the partials read them there):
;
;   DUTY_0, DUTY_1 = DUTY_BASE_n + LFO 1 × LFO1_DUTY + LFO 2 × LFO2_DUTY
;   RESONANCE      = RESONANCE_BASE + LFO 1 × LFO1_RESONANCE
;                    + LFO 2 × LFO2_RESONANCE
;
; The loop covers the channels the firmware says are in use.

        IDX     i, =#CHANNELS, 0
        LOOP.vi channels, CHANNELS_IN_USE, =#64
        IDX     j, [i+LFO1], 0                      ; j → LFO 1's record
        MAC     [i+TP], 0, [j+OUT], [i+LFO1_PITCH]
        MAC     [i+TC], 0, [j+OUT], [i+LFO1_CUTOFF]
        IDX     j, [i+LFO2], 0
        MAC     [i+TP], [i+TP], [j+OUT], [i+LFO2_PITCH]
        MAC     [i+TC], [i+TC], [j+OUT], [i+LFO2_CUTOFF]
        ADD3    [i+CH_PITCH], 0, [i+TP], [i+BEND]
        MAC     [i+TC], [i+TC], [i+CH_PITCH], [i+KEY_TRACK]
        ADD3    [i+CH_CUTOFF], 0, [i+TC], [i+CUTOFF_BASE]

        IDX     j, [i+LFO1], 0
        MAC     [i+TD], 0, [j+OUT], [i+LFO1_DUTY]
        MAC     [i+TR], 0, [j+OUT], [i+LFO1_RESONANCE]
        IDX     j, [i+LFO2], 0
        MAC     [i+TD], [i+TD], [j+OUT], [i+LFO2_DUTY]
        MAC     [i+TR], [i+TR], [j+OUT], [i+LFO2_RESONANCE]
        IDX     j, [i+SINK_BLOCK], 0                ; j → the channel's sinks
        ADD3    [j+DUTY_0], 0, [i+TD], [i+DUTY_BASE_0]
        ADD3    [j+DUTY_1], 0, [i+TD], [i+DUTY_BASE_1]
        ADD3    [j+RESONANCE], 0, [i+TR], [i+RESONANCE_BASE]
channels:
