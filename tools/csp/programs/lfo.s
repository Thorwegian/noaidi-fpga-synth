; lfo.s -- the LFOs, one update a pass: saw, square, triangle and sine
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; An LFO is a record of 16 words. Its phase is a wide register that runs
; from −8 to +8 and wraps (one cycle); the upper word is a sawtooth over
; that range, so the gains carry the scale. Each update adds RATE (a wide
; register: the firmware's csp::lfo_rate) and writes OUT, the wave at the new
; phase, as osc_core would, scaled by the depth: ±depth, where osc_core's
; output is ±0.5 at full scale.
;
; The records are sorted by shape, saws first, then squares, triangles and
; sines, and the firmware writes how many of each (N_SAW, …): a vector loop
; runs over each shape's records, so a shape costs only what its LFOs use,
; and a loop over none costs nothing. i runs on through the records.
;
;   saw       OUT = PHASE × GAIN               (GAIN = depth ÷ 8)
;   square    OUT = −depth when PHASE ≥ 0, else +depth (as osc_core's pulse)
;   triangle  OUT = |PHASE| × GAIN − depth     (GAIN = depth ÷ 4)
;   sine      OUT = depth × sin, as a parabola 4p − 4p|p| with p = PHASE ÷ 8,
;             and its error corrected: y + 0.225 (y|y| − y), good to 0.1 %
;
; The fields: DEPTH, NEG_DEPTH and GAIN (by the shape), the scratch words
; P, T and Z that a vector loop needs per record.

        .block LFO
        .field PHASE, 2         ; 0
        .field RATE, 2          ; 2
        .field DEPTH, 1         ; 4
        .field NEG_DEPTH, 1     ; 5
        .field GAIN, 1          ; 6
        .field OUT, 1           ; 7
        .field P, 1             ; 8
        .field T, 1             ; 9
        .field Z, 1             ; 10
        .end
        .equ   LFOS, 0x300
        .reg   N_SAW, 0x070
        .reg   N_SQUARE, 0x071
        .reg   N_TRIANGLE, 0x072
        .reg   N_SINE, 0x073
        .const ONE, 1.0
        .const EIGHTH, 0.125
        .const FOUR, 4.0
        .const MINUS_FOUR, -4.0
        .const CORRECTION, 0.225
        .const ONE_MINUS_CORRECTION, 0.775

        IDX     i, =#LFOS, 0
        LOOP.vi saws, N_SAW, =#16
        MACW.w  [i+PHASE], ONE, [i+RATE]            ; advance and wrap
        MAC     [i+OUT], 0, [i+PHASE], [i+GAIN]     ; ±depth
saws:
        LOOP.vi squares, N_SQUARE, =#16
        MACW.w  [i+PHASE], ONE, [i+RATE]
        CMP     ZERO, [i+PHASE], ZERO
        SEL     [i+OUT], [i+NEG_DEPTH], [i+DEPTH]   ; high while the phase is negative
squares:
        LOOP.vi triangles, N_TRIANGLE, =#16
        MACW.w  [i+PHASE], ONE, [i+RATE]
        ABS     [i+T], [i+PHASE]                    ; 0 … 8
        MAC     [i+T], 0, [i+T], [i+GAIN]           ; 0 … 2 × depth
        ADD3    [i+OUT], 0, [i+T], [i+NEG_DEPTH]    ; ±depth, low at phase 0
triangles:
        LOOP.vi sines, N_SINE, =#16
        MACW.w  [i+PHASE], ONE, [i+RATE]
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
