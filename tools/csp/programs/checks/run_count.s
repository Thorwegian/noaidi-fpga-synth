; run_count.s -- the passes this run made, for the chip check of the control program (#236)
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; After map.s and control_counts.s, before lfo.s: one a pass from the
; fill's value, wrapping, as every program in checks/ counts.
        .reg   RUN_ONE,   0x3FD
        .reg   RUN_COUNT, 0x3FE
        ADD3    RUN_ONE, 0, =1.0, ZERO
        MACW    RUN_COUNT, RUN_COUNT, RUN_ONE, =#1
