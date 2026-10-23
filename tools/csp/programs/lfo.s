; lfo.s -- the LFOs, every pass: saw, square, triangle, sine
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; After map.s and counts.s. An LFO is a record of the pool (map.s). Its
; phase is a wide register that runs from −8 to +8 and wraps (one cycle);
; the upper word is a sawtooth over that range, so the gains carry the
; scale. Each update adds PHASE_STEP (the firmware's csp::lfo_rate) and
; writes OUT, the wave at the new phase, as osc_core would, scaled by the
; depth: ±depth, where osc_core's output is ±0.5 at full scale.
;
; The LFOs run at 24 kHz, the pass rate (#268): the whole pool every pass.
; (At the 48 kHz pass the halves took turns, one each pass, for the same
; 24 kHz.) The pool's records are in two halves, each sorted by shape,
; saws first, then squares, triangles and sines, and the firmware writes
; in a set, one for each half, where it starts; how many of each shape
; there are is fixed in the program (counts.s). A vector loop runs over
; each shape's records, and i runs on through the records; the four loops
; are laid out once for each half.
;
;   saw       OUT = PHASE × GAIN               (GAIN = depth ÷ 8)
;   square    OUT = −depth when PHASE ≥ 0, else +depth (as osc_core's pulse)
;   triangle  OUT = |PHASE| × GAIN − depth     (GAIN = depth ÷ 4)
;   sine      OUT = depth × sin, as a parabola 4p − 4p|p| with p = PHASE ÷ 8,
;             and its error corrected: y + 0.225 (y|y| − y), good to 0.15 %

        IDX     j, =#LFO_SETS, 0                    ; j → the first half's set
        IDX     i, [j+BASE], 0                      ; i → its first record

        LOOP.vi saws, =#SAWS_A_HALF, =#LFO_SIZE
        MACW.w  [i+PHASE], ONE, [i+PHASE_STEP]      ; advance and wrap
        MAC     [i+OUT], 0, [i+PHASE], [i+GAIN]     ; ±depth
saws:
        LOOP.vi squares, =#SQUARES_A_HALF, =#LFO_SIZE
        MACW.w  [i+PHASE], ONE, [i+PHASE_STEP]
        CMP     ZERO, [i+PHASE], ZERO
        SEL     [i+OUT], [i+NEG_DEPTH], [i+DEPTH]   ; high while the phase is negative
squares:
        LOOP.vi triangles, =#TRIANGLES_A_HALF, =#LFO_SIZE
        MACW.w  [i+PHASE], ONE, [i+PHASE_STEP]
        ABS     [i+T], [i+PHASE]                    ; 0 … 8
        MAC     [i+T], 0, [i+T], [i+GAIN]           ; 0 … 2 × depth
        ADD3    [i+OUT], 0, [i+T], [i+NEG_DEPTH]    ; ±depth, low at phase 0
triangles:
        LOOP.vi sines, =#SINES_A_HALF, =#LFO_SIZE
        MACW.w  [i+PHASE], ONE, [i+PHASE_STEP]
        MAC     [i+P], 0, [i+PHASE], EIGHTH         ; p = phase ÷ 8, −1 … 1
        ABS     [i+T], [i+P]
        MAC     [i+T], 0, [i+T], [i+P]              ; p|p|
        MAC     [i+T], 0, [i+T], MINUS_FOUR         ; −4p|p|
        MAC     [i+T], [i+T], [i+P], FOUR           ; y = 4p − 4p|p|
        ABS     [i+Z], [i+T]
        MAC     [i+Z], 0, [i+T], [i+Z]              ; y|y|
        MAC     [i+OUT], 0, [i+T], ONE_MINUS_CORRECTION
        MAC     [i+OUT], [i+OUT], [i+Z], CORRECTION ; y + 0.225 (y|y| − y)
        MAC     [i+OUT], 0, [i+OUT], [i+DEPTH]      ; × depth
sines:

        ; the second half, the same four loops
        IDX     j, =#LFO_SET_1, 0                   ; j → the second half's set
        IDX     i, [j+BASE], 0                      ; i → its first record

        LOOP.vi saws_1, =#SAWS_A_HALF, =#LFO_SIZE
        MACW.w  [i+PHASE], ONE, [i+PHASE_STEP]      ; advance and wrap
        MAC     [i+OUT], 0, [i+PHASE], [i+GAIN]     ; ±depth
saws_1:
        LOOP.vi squares_1, =#SQUARES_A_HALF, =#LFO_SIZE
        MACW.w  [i+PHASE], ONE, [i+PHASE_STEP]
        CMP     ZERO, [i+PHASE], ZERO
        SEL     [i+OUT], [i+NEG_DEPTH], [i+DEPTH]   ; high while the phase is negative
squares_1:
        LOOP.vi triangles_1, =#TRIANGLES_A_HALF, =#LFO_SIZE
        MACW.w  [i+PHASE], ONE, [i+PHASE_STEP]
        ABS     [i+T], [i+PHASE]                    ; 0 … 8
        MAC     [i+T], 0, [i+T], [i+GAIN]           ; 0 … 2 × depth
        ADD3    [i+OUT], 0, [i+T], [i+NEG_DEPTH]    ; ±depth, low at phase 0
triangles_1:
        LOOP.vi sines_1, =#SINES_A_HALF, =#LFO_SIZE
        MACW.w  [i+PHASE], ONE, [i+PHASE_STEP]
        MAC     [i+P], 0, [i+PHASE], EIGHTH         ; p = phase ÷ 8, −1 … 1
        ABS     [i+T], [i+P]
        MAC     [i+T], 0, [i+T], [i+P]              ; p|p|
        MAC     [i+T], 0, [i+T], MINUS_FOUR         ; −4p|p|
        MAC     [i+T], [i+T], [i+P], FOUR           ; y = 4p − 4p|p|
        ABS     [i+Z], [i+T]
        MAC     [i+Z], 0, [i+T], [i+Z]              ; y|y|
        MAC     [i+OUT], 0, [i+T], ONE_MINUS_CORRECTION
        MAC     [i+OUT], [i+OUT], [i+Z], CORRECTION ; y + 0.225 (y|y| − y)
        MAC     [i+OUT], 0, [i+OUT], [i+DEPTH]      ; × depth
sines_1:
