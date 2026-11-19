; index_wait.s -- rows in an IDX's wait, for the chip check
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; An IDX's index is in its register five cycles after the IDX issues, and the
; assembler places only the rows that use that index register behind it: the
; rows between use the other index register, or none.
;
; The first part has bases the assembler knows, so nothing but the index is
; waited for: the rows in the waits are a row with direct operands and the
; other register's IDX, and each index is used in the first cycle it can be.
; A row that used i too early would use the block i was left at by the pass
; before. The second part points the indexes at blocks that change every
; pass, by a register and by a pointer read through the other index, with a
; row through the other index in the wait.
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
            ADD3   S_, 0, A_, RUN_COUNT         ; the count is ready from here on
            IDX    i, =#0x200, 0
            ADD3   C_, 0, A_, B_                ; in i's wait: a row that uses no index
            IDX    j, =#0x240, 0                ;   and the other register's IDX
            MAC    D_, 0, A_, =0.5              ; in both waits
            MAC    T_, 0, B_, =0.5
            ADD3   [i+Y], 0, [i+X], RUN_COUNT   ; the first cycle i can be used
            MAC    [i+Z], 0, [i+X], =0.5        ; j is in flight still
            ADD3   [j+Y], 0, [j+X], RUN_COUNT   ; the first cycle j can be used

            ANDXOR T_, 0, RUN_COUNT, =#7
            SHIFT  T_, T_, =#3                  ; a block's offset, another every pass: 0, 8 … 56
            IDX    i, =#0x280, T_
            ADD3   S_, 0, A_, B_                ; in its wait
            IDX    j, =#0x2C0, T_
            ADD3   [i+Y], 0, [i+X], RUN_COUNT   ; behind an index set from a register, a row
            ADD3   [j+Y], 0, [j+X], S_          ;   waits for every earlier write as well
            ADD3   [j+Z], 0, =#0x300, T_        ; a pointer to a third block, written through j
            IDX    i, [j+Z], ZERO               ; i again: its operand read through j
            MAC    [j+SPARE], 0, [j+Y], =0.5    ; in i's wait: a row through the other index
            ADD3   [i+Y], 0, [i+X], [j+SPARE]   ; i is at the third block
