; vector_4_stride_1.s -- four elements, stride 1, one row (#236)
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
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
            LOOP.vi end_v, =#4, =#1
            ADD3   [i+0], 0, =1.0, ZERO
end_v:
