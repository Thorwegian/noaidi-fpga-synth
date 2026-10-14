; lfo.s -- the LFOs, one update every other pass: saw, square, triangle, sine
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; After map.s. An LFO is a record of the pool (map.s). Its phase is a wide
; register that runs from −8 to +8 and wraps (one cycle); the upper word is
; a sawtooth over that range, so the gains carry the scale. Each update
; adds PHASE_STEP (the firmware's csp::lfo_rate) and writes OUT, the wave at
; the new phase, as osc_core would, scaled by the depth: ±depth, where
; osc_core's output is ±0.5 at full scale.
;
; The LFOs run at 24 kHz: half of the 32 each pass, the other half in the
; next, so a pass costs 16 at most. The pool's records are in two halves,
; each sorted by shape, saws first, then squares, triangles and sines, and
; the firmware writes in a set, one for each half, where it starts and
; how many of each shape there are: a vector loop runs over each shape's
; records, so a shape costs only what its LFOs use, and a loop over none
; costs nothing. i runs on through the records.
;
;   saw       OUT = PHASE × GAIN               (GAIN = depth ÷ 8)
;   square    OUT = −depth when PHASE ≥ 0, else +depth (as osc_core's pulse)
;   triangle  OUT = |PHASE| × GAIN − depth     (GAIN = depth ÷ 4)
;   sine      OUT = depth × sin, as a parabola 4p − 4p|p| with p = PHASE ÷ 8,
;             and its error corrected: y + 0.225 (y|y| − y), good to 0.15 %

        ANDXOR  PARITY, 0, PASS, =#1                ; which half this pass
        SHIFT   PARITY, PARITY, =#3                 ; × the size of a set (8)
        IDX     j, =#LFO_SETS, PARITY               ; j → this half's set
        IDX     i, [j+BASE], 0                      ; i → its first record

        LOOP.vi saws, [j+N_SAW], =#12
        MACW.w  [i+PHASE], ONE, [i+PHASE_STEP]      ; advance and wrap
        MAC     [i+OUT], 0, [i+PHASE], [i+GAIN]     ; ±depth
saws:
        LOOP.vi squares, [j+N_SQUARE], =#12
        MACW.w  [i+PHASE], ONE, [i+PHASE_STEP]
        CMP     ZERO, [i+PHASE], ZERO
        SEL     [i+OUT], [i+NEG_DEPTH], [i+DEPTH]   ; high while the phase is negative
squares:
        LOOP.vi triangles, [j+N_TRIANGLE], =#12
        MACW.w  [i+PHASE], ONE, [i+PHASE_STEP]
        ABS     [i+T], [i+PHASE]                    ; 0 … 8
        MAC     [i+T], 0, [i+T], [i+GAIN]           ; 0 … 2 × depth
        ADD3    [i+OUT], 0, [i+T], [i+NEG_DEPTH]    ; ±depth, low at phase 0
triangles:
        LOOP.vi sines, [j+N_SINE], =#12
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
