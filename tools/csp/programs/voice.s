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
;   gain   = OUT_A                                  the fraction of the
;                                                   pipeline's 60 dB span
;                                                   (the amp envelope ×
;                                                   velocity, envelope.s)
;
; written to the voice's three sinks, the words the program owns for a voice.
; The partial pipeline takes the gain's exponential, as the old engine's
; attenuation LUT did, so the envelope's level moves the gain in dB and the
; preset's volume is in the channel's left and right gains. The scratch fields
; hold the pitch and the cutoff (U_A, U_M) until the sinks are addressed: j
; points at the channel first, then at the sinks.

        IDX     i, =#VOICES, 0
        LOOP.vi voices, =#VOICE_COUNT, =#VOICE_SIZE
        IDX     j, [i+CHANNEL], 0                   ; j → the channel
        ADD3    [i+U_A], 0, [i+NOTE], [j+CH_PITCH]
        MAC     [i+U_M], 0, [i+U_M], [j+MOD_AMOUNT]     ; U_M: the mod envelope's output (envelope.s)
        SHIFT   [i+U_M], [i+U_M], =#2                   ; × 4: MOD_AMOUNT is a quarter of the depth, which
                                                        ;   reaches 32 octaves; a word holds 8
        MAC     [i+U_M], [i+U_M], [i+NOTE], [j+KEY_TRACK]
        ADD3    [i+U_M], [i+U_M], [j+CH_CUTOFF], 0
        IDX     j, [i+SINK], 0                      ; j → the voice's sinks
        MAC     [j+SINK_PITCH], 0, [i+U_A], ONE
        MAC     [j+SINK_CUTOFF], 0, [i+U_M], ONE
        MAC     [j+SINK_GAIN], 0, [i+OUT_A], ONE
voices:
