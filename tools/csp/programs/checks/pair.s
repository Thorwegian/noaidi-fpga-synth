; pair.s -- the wide pair's write and read alone, for the chip check (#235)
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; At 96 MHz the pair V_ came out wrong by the same value every pass while the
; pair it is computed from was right. Here the pair write and the wide read
; are one row each, far apart, on operands the fill set and nothing changes:
; a wrong V_ is the pair write (or the wide read of W_), a wrong U_ with a
; right V_ is the wide read of a pair the chip wrote.
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
        .wide U_, 0x06A
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
            ADD3.w   V_, D_, W_                 ; the pair write, from a word and a pair the fill set
            MAC.w    U_, A_, V_                 ; the wide read of the pair the chip wrote
            ADD3     T_, 0, =0.25, ZERO
