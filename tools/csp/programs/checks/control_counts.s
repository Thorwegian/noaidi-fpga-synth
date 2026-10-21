; control_counts.s -- the control program's loop counts for the chip check (#236)
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; In place of counts.s: one sine fewer than the firmware's layout, which
; sits at the pass's limit of 1472 cycles, so that run_count.s's two rows
; fit and `csp match` knows how many passes the chip ran.
        .equ   SAWS_A_HALF, 0
        .equ   SQUARES_A_HALF, 6
        .equ   TRIANGLES_A_HALF, 0
        .equ   SINES_A_HALF, 5
