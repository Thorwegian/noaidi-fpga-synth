; envelope.s -- the RC envelopes of every voice, one segment step a pass
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; After map.s. A voice has two envelopes, amp (A) and mod (M). Each channel
; keeps an envelope table at the address its voices' CHANNEL field holds:
; three rows of four words for the amp envelope's attack (+0), decay
; (+4) and release (+8), and three for the mod envelope's (+16, +20, +24). A
; row is two wide registers: the segment's target (1.3 for the attack, the
; sustain level, 0) and its rate. A segment moves the level toward its
; target by the fraction RATE of the distance left each pass: an RC charge,
; as adsr.sv at 96 kHz (the firmware converts, app/main/csp/envelope.hpp).
; The rate is wide, Q4.32, so it can be as slow as adsr.sv's 2^-24: a
; word's smallest step would be 2^-14, a time constant of 0.34 s at 48 kHz.
; The distance is a word: the upper words of target and level, subtracted.
; The level stops within a word's step (2^-14) of its target.
;
; A voice holds, for each envelope, its level (wide) and stage (the row's
; offset in the table: 0, 4 or 8, and 16, 20 or 24), its velocity and the
; mod envelope's (the amounts a note's velocity sets), the outputs, and
; scratch fields (U per envelope, D), per voice because a vector loop's
; iterations must not share registers.
;
; The stages are the firmware's to start and to end (#267): a note-on
; writes attack (0 and 16) to both envelopes, from whatever level the voice
; is at, so a stolen voice retriggers; a note-off writes release (8 and
; 24); an idle voice sits in release at level 0. The program owns the one
; transition that depends on the level: attack → decay when the level
; reaches full scale. It is worked out first, from the level the previous
; pass left, and j is set from it, so the change takes effect in the same
; pass, as in adsr.sv (the attack ends in the pass after the level reaches
; full scale). SEL reads the flags of the CMP before it, so the MAX of a
; stage comes ahead of the CMP of its level; MAX leaves decay and release
; where they are (4 and 8 are at least 4, 20 and 24 at least 20).
;
; The loop is a vector loop (LOOP.vi): the body runs instruction by
; instruction across the voices, so nothing waits for a result. (The voice
; and segment layouts are in map.s.)

        IDX     i, =#VOICES, 0              ; i → voice 0
        LOOP.vi done, =#VOICE_COUNT, =#VOICE_SIZE   ; every voice (counts.s)
        MAX     [i+U_A], [i+STAGE_A], =#4   ;   attack → decay, if…
        MAX     [i+U_M], [i+STAGE_M], =#20
        CMP     ZERO, [i+LEVEL_A], FULL     ;   …full scale is reached
        SEL     [i+STAGE_A], [i+U_A], [i+STAGE_A]   ; (SEL reads the CMP's flags)
        CMP     ZERO, [i+LEVEL_M], FULL
        SEL     [i+STAGE_M], [i+U_M], [i+STAGE_M]

        IDX     j, [i+CHANNEL], [i+STAGE_A] ;   the amp envelope: j → its row
        CMP     [i+D], [j+TARGET], [i+LEVEL_A]  ; D ← target − level
        MAC.w   [i+LEVEL_A], [i+D], [j+RATE]    ; level ← level + D × rate
        MAC     [i+OUT_A], 0, [i+LEVEL_A], [i+VELOCITY]

        IDX     j, [i+CHANNEL], [i+STAGE_M] ;   the mod envelope
        CMP     [i+D], [j+TARGET], [i+LEVEL_M]
        MAC.w   [i+LEVEL_M], [i+D], [j+RATE]
        MAC     [i+U_M], 0, [i+LEVEL_M], [i+VELOCITY_M]   ; the mod envelope's output
done:
