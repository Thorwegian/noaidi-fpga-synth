; vector_flags.s -- a vector loop choosing by each element's own flags and index (#236)
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; The envelope's loop (envelope.s) compares a level, selects a stage by the
; flags, points j at the stage's row through an IDX and accumulates a wide
; level from what j reads: the per-element flags and the per-element other
; index, which vloop.s and the four micro-programs never touch. The same
; shapes over four items whose fill puts two elements below the threshold
; and two above.
;
; The registers every check shares, and the two rows at the top that count
; the passes run (RUN_COUNT wraps), so that `csp match` runs the model for
; exactly as many passes as the chip did:
        .reg A_, 0x060
        .reg B_, 0x061
        .reg C_, 0x062
        .reg D_, 0x063
        .wide W_, 0x064
        .wide V_, 0x066
        .reg S_, 0x068
        .reg T_, 0x069
        .block ITEM
        .field X, 1
        .field Y, 1
        .field Z, 1
        .field W, 1
        .field L, 2
        .field D, 1
        .field SPARE, 1
        .end
        .reg RUN_ONE, 0x3FD
        .reg RUN_COUNT, 0x3FE
        ADD3   RUN_ONE, 0, =1.0, ZERO
        MACW   RUN_COUNT, RUN_COUNT, RUN_ONE, =#1
            IDX    i, =#0x200, 0
            LOOP.vi end_v, =#4, =#8
            CMP    ZERO, [i+X], =#19500             ; the fill's X: 18951, 19247 below; 19543, 19839 above
            SEL    [i+Y], A_, B_                    ; negative: B_, else A_: by this element's flags
            ANDXOR [i+W], 0, [i+X], =#0x38          ; W = X & 0x38: 0, 40, 16, 56 for the four
            IDX    j, =#0x240, [i+W]                ; this element's j
            MAC    [i+Z], 0, [j+0], =1.0            ; Z = the register j names
            CMP    [i+D], [j+0], [i+X]              ; D = that register - X, the flags set again
            SEL    [i+SPARE], [i+Y], =0.25          ; negative: 0.25, else Y
            MAC.w  [i+L], [i+D], W_                 ; L += D x W_ (a pair the fill set), wide, in place
            IDX    j, =#0x280, [i+W]                ; this element's j again, elsewhere
            ADD3   [j+0], 0, [i+Z], =0.125          ; a write through it
end_v:
            ADD3   S_, S_, =#1, ZERO                ; after the loop: once a pass
