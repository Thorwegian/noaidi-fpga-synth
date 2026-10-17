; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; vecidx_test.s -- the voice loop's pattern in miniature: a vector loop whose
; body points j at a table through each element's own field, then reads
; through it. Element k (records of 16 words from 0x300): F (+5) holds the
; address of its table, N (+14) 0, and U (+6) must end up as the table's word
; at +39. Tables at 0x200 (0x1111) and 0x240 (0x2222). COUNT elements.
        .reg   COUNT, 0x062
        IDX     i, =#0x300, 0
        LOOP.vi done, COUNT, =#16
        IDX     j, [i+5], 0
        ADD3    [i+6], 0, [i+14], [j+39]
done:
