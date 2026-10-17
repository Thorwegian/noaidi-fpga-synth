; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; Run with: tools/lab/lab.sh WAIT "ADDR COUNT" tools/csp/programs/map.s tools/lab/programs/gap3_test.s
; gap3_test.s -- operand slot X and Y, gaps 0..4
        .reg   Ax0, 0x062
        .reg   Bx0, 0x064
        .reg   Ax1, 0x066
        .reg   Bx1, 0x068
        .reg   Ax2, 0x06a
        .reg   Bx2, 0x06c
        .reg   Ax3, 0x06e
        .reg   Bx3, 0x070
        .reg   Ax4, 0x072
        .reg   Bx4, 0x074
        .reg   Ay0, 0x076
        .reg   By0, 0x078
        .reg   Ay1, 0x07a
        .reg   By1, 0x07c
        .reg   Ay2, 0x07e
        .reg   By2, 0x080
        .reg   Ay3, 0x082
        .reg   By3, 0x084
        .reg   Ay4, 0x086
        .reg   By4, 0x088
        ADD3    Ax0, 0, ONE, ZERO
        ADD3    Bx0, 0, Ax0, ZERO
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        ADD3    Ax1, 0, ONE, ZERO
        NOP
        ADD3    Bx1, 0, Ax1, ZERO
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        ADD3    Ax2, 0, ONE, ZERO
        NOP
        NOP
        ADD3    Bx2, 0, Ax2, ZERO
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        ADD3    Ax3, 0, ONE, ZERO
        NOP
        NOP
        NOP
        ADD3    Bx3, 0, Ax3, ZERO
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        ADD3    Ax4, 0, ONE, ZERO
        NOP
        NOP
        NOP
        NOP
        ADD3    Bx4, 0, Ax4, ZERO
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        ADD3    Ay0, 0, ONE, ZERO
        ADD3    By0, 0, ZERO, Ay0
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        ADD3    Ay1, 0, ONE, ZERO
        NOP
        ADD3    By1, 0, ZERO, Ay1
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        ADD3    Ay2, 0, ONE, ZERO
        NOP
        NOP
        ADD3    By2, 0, ZERO, Ay2
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        ADD3    Ay3, 0, ONE, ZERO
        NOP
        NOP
        NOP
        ADD3    By3, 0, ZERO, Ay3
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        ADD3    Ay4, 0, ONE, ZERO
        NOP
        NOP
        NOP
        NOP
        ADD3    By4, 0, ZERO, Ay4
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
        NOP
