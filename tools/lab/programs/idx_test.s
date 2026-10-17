; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; Run with: tools/lab/lab.sh WAIT "ADDR COUNT" tools/csp/programs/map.s tools/lab/programs/idx_test.s
; idx_test.s -- does IDX j, then a read through [j+...], see the new j?
        .reg   HALF_T, 0x062
        .reg   RESULT, 0x064
        .reg   TBL0,   0x063
        .reg   TBL1,   0x06B
        .equ   TABLE,  0x063
        ADD3    HALF_T, 0, ONE, ZERO
        SHIFT   HALF_T, HALF_T, =#-11
        MAC     TBL0, 0, ONE, ONE
        MAC     TBL1, 0, EIGHTH, ONE
        IDX     j, =#TABLE, HALF_T
        MAC     RESULT, 0, [j+BASE], ONE
