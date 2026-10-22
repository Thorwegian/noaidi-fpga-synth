; loop.s -- the scalar loop's repeat alone, for the chip check (#235)
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; At 96 MHz the chip wrote the first iteration of every scalar loop and none
; after it, and ran rows before the loops again within a pass: the repeat's
; redirect. This program has nothing else: a loop on i and one on j, bodies of
; one row with no dependence, and one row after them that counts the passes
; the rows after the loops see. Which iterations land says where the PC went.
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
            IDX    i, =#0x200, 0
            LOOP.i end_i, =#4, =#8
            ADD3   [i+X], 0, =1.0, ZERO
end_i:
            IDX    j, =#0x240, 0
            LOOP.j end_j, =#3, =#1
            ADD3   [j+0], 0, =0.5, ZERO
end_j:
            ADD3   S_, S_, =#1, ZERO            ; after the loops: once a pass, if the PC comes here once
