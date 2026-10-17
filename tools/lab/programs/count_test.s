; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; Run with: tools/lab/lab.sh WAIT "ADDR COUNT" tools/csp/programs/map.s tools/lab/programs/count_test.s
        .const RAW_ONE, 0.00006103515625
        .reg   CNT_TOTAL, 0x062
        .reg   CNT_BIT,   0x064
        .reg   BIT_NOW,   0x066
        ADD3    CNT_TOTAL, CNT_TOTAL, RAW_ONE, ZERO
        ANDXOR  BIT_NOW, 0, PASS, =#1
        ADD3    CNT_BIT, CNT_BIT, BIT_NOW, ZERO
