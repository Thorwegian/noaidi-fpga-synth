; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; vec2_test.s -- two vector loops one after the other, as lfo.s runs its
; shapes: the first counts N_FIRST elements, the second N_SECOND, the second
; carrying on in the records where the first stopped. Each element adds ONE to
; the first word of its record (4 words a record, from BLOCK).
;
; Run with: tools/lab/snapshot.py after loading it (tools/lab/lab.sh) and
; `csp replay map.s vec2_test.s`.
        .reg   N_FIRST,  0x062
        .reg   N_SECOND, 0x063
        .equ   BLOCK,    0x300
        IDX     i, =#BLOCK, 0
        LOOP.vi first, N_FIRST, =#4
        MAC     [i+0], [i+0], ONE, ONE
first:
        LOOP.vi second, N_SECOND, =#4
        MAC     [i+0], [i+0], ONE, ONE
second:
