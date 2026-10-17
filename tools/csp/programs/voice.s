; voice.s -- a voice's pitch, cutoff and gain, and their sinks
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; After map.s, lfo.s, channel.s and envelope.s. For each of the 32 voices (a
; vector loop), with its channel's values (channel.s) and its envelopes'
; outputs (envelope.s):
;
;   pitch  = NOTE + CH_PITCH                        octaves
;   cutoff = 4 × U_M × MOD_AMOUNT + NOTE × KEY_TRACK + CH_CUTOFF   octaves
;   gain   = OUT_A × VOLUME                         linear (OUT_A is the
;                                                   amp envelope × velocity)
;
; written to the voice's three sinks, the words the program owns for a voice.
; The scratch fields hold the three results (U_A, U_M, D) until the sinks
; are addressed: j points at the channel first, then at the sinks.

        IDX     i, =#VOICES, 0
        LOOP.vi voices, =#32, =#16
        IDX     j, [i+CHANNEL], 0                   ; j → the channel
        ADD3    [i+U_A], 0, [i+NOTE], [j+CH_PITCH]
        MAC     [i+U_M], 0, [i+U_M], [j+MOD_AMOUNT]     ; U_M: the mod envelope's output (envelope.s)
        SHIFT   [i+U_M], [i+U_M], =#2                   ; × 4: MOD_AMOUNT is a quarter of the depth, which
                                                        ;   reaches 32 octaves; a word holds 8
        MAC     [i+U_M], [i+U_M], [i+NOTE], [j+KEY_TRACK]
        ADD3    [i+U_M], [i+U_M], [j+CH_CUTOFF], 0
        MAC     [i+D], 0, [i+OUT_A], [j+VOLUME]
        IDX     j, [i+SINK], 0                      ; j → the voice's sinks
        MAC     [j+SINK_PITCH], 0, [i+U_A], ONE
        MAC     [j+SINK_CUTOFF], 0, [i+U_M], ONE
        MAC     [j+SINK_GAIN], 0, [i+D], ONE
voices:
