; flags.s -- rows between a CMP and its SEL, for the chip check
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; CMP alone sets the flags, so in scalar code, with its one set of flags, any
; other rows may stand between a CMP and the SEL that reads it. Here rows of
; every kind stand there, the SEL in the first cycle the CMP's flags can be
; read, and the CMP's sign changes every pass while the rows between have
; results of both signs. A row that set the flags would turn a SEL: S_ and
; T_ would hold the other of A_ and B_ than the model's.
;
; The registers and the block every check shares, and the two rows at the top
; that count the passes run (RUN_COUNT wraps), so that `csp match` runs the
; model for exactly as many passes as the chip did:
        .reg A_, 0x060
        .reg B_, 0x061
        .reg C_, 0x062
        .reg D_, 0x063
        .dword W_, 0x064
        .dword V_, 0x066
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
        .reg ODD, 0x06C
        .reg U_, 0x06D
        ADD3   RUN_ONE, 0, =1.0, ZERO
        MACW   RUN_COUNT, RUN_COUNT, RUN_ONE, =#1
            ANDXOR ODD, 0, RUN_COUNT, =#1       ; 0 or 1, by the pass
            MAC    U_, 0, A_, =0.5              ; (the rows between read these)
            ABS    C_, B_
            CMP    ZERO, ODD, =#1               ; negative on an even pass, zero on an odd one
            MAC    D_, 0, A_, B_                ; between: the multiply-add,
            SUB    D_, B_, A_                   ;   the subtraction that leaves the flags,
            ADD3   D_, 0, A_, B_
            MAX    D_, A_, B_                   ;   the logic unit,
            SHIFT  U_, U_, =#1                  ;   the shifter
            SEL    S_, A_, B_                   ; negative: B_, else A_
            CMP    ZERO, ZERO, ODD              ; the other way round: negative on an odd pass
            ANDXOR D_, 0, A_, B_
            ABS    D_, A_
            MACW   C_, C_, A_, =0.5
            MIN    D_, A_, B_
            SUB    D_, A_, B_
            SEL    T_, A_, B_
