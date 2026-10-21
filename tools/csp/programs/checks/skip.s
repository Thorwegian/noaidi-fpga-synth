; skip.s -- a directed program of the co-simulation, run on the model, the RTL and the chip
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; The registers and the block every check shares, and the two rows at the top
; that count the passes run (RUN_COUNT wraps), so that `csp match` runs the
; model for exactly as many passes as the chip did:
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
        .field SPARE, 5
        .end
        .reg RUN_ONE, 0x3FD
        .reg RUN_COUNT, 0x3FE
        ADD3   RUN_ONE, 0, =1.0, ZERO
        MACW   RUN_COUNT, RUN_COUNT, RUN_ONE, =#1
            CMP    ZERO, A_, B_
            SKIP   neg, 2
            MAC    C_, 0, =1.0, A_
            MAC    D_, 0, =2.0, B_
            MAC    S_, S_, =0.5, C_
            CMP    ZERO, B_, A_
            SEL    T_, C_, D_
            IDX    i, =#0x200, 0
            LOOP.i end, =#4, =#8
            CMP    ZERO, [i+X], [i+Y]
            SKIP   pos, 1
            ADD3   [i+Z], [i+Z], =0.25, ZERO
            MAC    A_, A_, =0.0625, S_
end:
