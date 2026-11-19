; index_wait.s -- rows in an IDX's wait, for the chip check
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; An IDX's index is in its register five cycles after the IDX issues, and the
; assembler places only the rows that use that index register behind it: the
; rows between use the other index register, or none. Here every kind of row
; stands in a wait: a row with direct operands, the other register's IDX, a
; row through the other index, and an IDX whose own operand is read through
; the other index. The blocks the indexes point at change every pass, so a row
; that used an index too early, or one that was held up, leaves its result in
; another block than the model's.
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
        ADD3   RUN_ONE, 0, =1.0, ZERO
        MACW   RUN_COUNT, RUN_COUNT, RUN_ONE, =#1
            ANDXOR T_, 0, RUN_COUNT, =#7
            SHIFT  T_, T_, =#3                  ; a block's offset, another every pass: 0, 8 … 56
            IDX    i, =#0x200, T_               ; i lands five cycles on
            ADD3   S_, 0, A_, B_                ; in its wait: a row that uses no index
            IDX    j, =#0x280, T_               ;   and the other register's IDX
            MAC    D_, 0, A_, =0.5              ; in both waits
            ADD3   [i+Y], 0, [i+X], RUN_COUNT   ; i has landed, j is in flight
            ADD3   [j+Y], 0, [j+X], S_          ; j has landed
            ADD3   [j+Z], 0, =#0x2C0, T_        ; a pointer to a third block, written through j
            IDX    i, [j+Z], ZERO               ; i again: its operand read through j
            MAC    [j+SPARE], 0, [j+Y], =0.5    ; in i's wait: a row through the other index
            ADD3   C_, 0, D_, S_                ;   and one through none
            ADD3   [i+Y], 0, [i+X], [j+SPARE]   ; i has landed on the third block
