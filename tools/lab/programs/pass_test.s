; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; Run with: tools/lab/lab.sh WAIT "ADDR COUNT" tools/csp/programs/map.s tools/lab/programs/pass_test.s
        .reg   PX,  0x062
        .reg   PY,  0x064
        .reg   PXA, 0x066
        .reg   PAND, 0x068
        ADD3    PX, 0, PASS, ZERO
        ADD3    PY, 0, ZERO, PASS
        ANDXOR  PAND, 0, PASS, =#1
