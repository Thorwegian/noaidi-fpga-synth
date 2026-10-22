; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; Run with: tools/lab/lab.sh WAIT "ADDR COUNT" tools/csp/programs/map.s tools/lab/programs/shift_test.s
        .reg   SA, 0x062
        .reg   SB, 0x064
        .reg   SC, 0x066
        .reg   SD, 0x068
        ADD3    SA, 0, ONE, ZERO
        ADD3    SB, 0, SA, ZERO
        SHIFT   SB, SB, =#-11
        ADD3    SC, 0, SB, ZERO
