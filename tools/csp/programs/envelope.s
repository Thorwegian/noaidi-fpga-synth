; envelope.s -- the RC envelopes of every voice, one segment step a pass
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; A voice has two envelopes, amp (A) and mod (M), which share its gate. Each
; channel keeps an envelope table at the address its voices' CHANNEL field
; holds: three rows of four words for the amp envelope's attack (+0), decay
; (+4) and release (+8), and three for the mod envelope's (+16, +20, +24). A
; row is the segment's target (wide: 1.3 for the attack, the sustain level,
; 0), its rate and its shift. A segment moves the level toward its target
; by the fraction RATE × 2^SHIFT / 16384 of the distance left each pass: an
; RC charge, as adsr.sv at 96 kHz (the firmware converts, app/main/csp/
; envelope.hpp). The shift is what reaches slow segments: a rate is a Q4.14
; word, whose smallest step is 2^-14, a time constant of 0.34 s at 48 kHz, and
; a shift of -10 brings it down to adsr.sv's 2^-24.
;
; A voice holds, for each envelope, its level (wide) and stage (the row's
; offset in the table: 0, 4 or 8, and 16, 20 or 24), and the voice's gate,
; velocity, the outputs, and scratch fields (U per envelope, DELTA), per
; voice because a vector loop's iterations must not share registers. The
; firmware starts an idle voice in release (8 and 24), and sets its levels
; to 0 at a note-on.
;
; The stage is worked out first, from the gate and from the level the
; previous pass left, and j is set from it, so a stage change takes effect in
; the same pass, as in adsr.sv (the attack ends in the pass after the level
; reaches full scale). SEL reads the flags of the CMP before it, so the MAX
; of a stage comes ahead of the CMP of its level. The gate is compared once,
; for both envelopes.
;
; The loop is a vector loop (LOOP.vi): the body runs instruction by
; instruction across the voices, so nothing waits for a result.

        .block VOICE
        .field LEVEL_A, 2       ; 0
        .field STAGE_A, 1       ; 2
        .field GATE, 1          ; 3
        .field VELOCITY, 1      ; 4
        .field CHANNEL, 1       ; 5: the address of the channel's envelope table
        .field U_A, 1           ; 6
        .field U_M, 1           ; 7
        .field LEVEL_M, 2       ; 8
        .field STAGE_M, 1       ; 10
        .field OUT_A, 1         ; 11
        .field DELTA, 2         ; 12
        .field OUT_M, 1         ; 14
        .end
        .block SEGMENT
        .field TARGET, 2
        .field RATE, 1
        .field SHIFT, 1
        .end
        .equ   VOICES, 0x600
        .const FULL, 1.0
        .const ONE, 1.0
        .const MINUS_ONE, -1.0

        IDX     i, =#VOICES, 0              ; i → voice 0
        LOOP.vi done, =#8, =#16             ; every voice
        MAX     [i+U_A], [i+STAGE_A], =#4   ;   attack → decay, if…
        MAX     [i+U_M], [i+STAGE_M], =#20
        CMP     ZERO, [i+LEVEL_A], FULL     ;   …full scale is reached
        SEL     [i+STAGE_A], [i+U_A], [i+STAGE_A]   ; (SEL reads the CMP's flags)
        CMP     ZERO, [i+LEVEL_M], FULL
        SEL     [i+STAGE_M], [i+U_M], [i+STAGE_M]
        ANDXOR  [i+U_A], 0, [i+STAGE_A], =#4    ; release → attack: 0/4/8 → 0/4/0
        ANDXOR  [i+U_M], 0, [i+STAGE_M], =#20   ;   and 16/20/24 → 16/20/16
        CMP     ZERO, [i+GATE], FULL        ;   gate held?
        SEL     [i+STAGE_A], [i+U_A], =#8   ;     else release
        SEL     [i+STAGE_M], [i+U_M], =#24

        IDX     j, [i+CHANNEL], [i+STAGE_A] ;   the amp envelope: j → its row
        INTERP.w [i+DELTA], ONE, [j+TARGET]     ; DELTA ← target
        MAC.w   [i+DELTA], MINUS_ONE, [i+LEVEL_A]   ; DELTA ← target − level
        SHIFT.w [i+DELTA], [j+SHIFT]        ;   DELTA ← DELTA × 2^SHIFT
        MAC.w   [i+LEVEL_A], [j+RATE], [i+DELTA]    ; level ← level + rate × DELTA
        MAC     [i+OUT_A], 0, [i+LEVEL_A], [i+VELOCITY]

        IDX     j, [i+CHANNEL], [i+STAGE_M] ;   the mod envelope
        INTERP.w [i+DELTA], ONE, [j+TARGET]
        MAC.w   [i+DELTA], MINUS_ONE, [i+LEVEL_M]
        SHIFT.w [i+DELTA], [j+SHIFT]
        MAC.w   [i+LEVEL_M], [j+RATE], [i+DELTA]
        MAC     [i+OUT_M], 0, [i+LEVEL_M], ONE
done:
