; vloop.s -- the vector loop alone, for the chip check (#235)
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; The control program is vector loops (the LFOs, the channels, the voices);
; the co-simulation's directed programs have only scalar ones. One vector
; loop on i over four items, a body of two rows, one of them dependent on
; the other, and a row after it.
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
            LOOP.vi end_v, =#4, =#8
            MAC    [i+Z], 0, [i+Y], =0.5
            ADD3   [i+X], [i+X], [i+Z], ZERO
end_v:
            ADD3   S_, S_, =#1, ZERO            ; after the loop: once a pass
