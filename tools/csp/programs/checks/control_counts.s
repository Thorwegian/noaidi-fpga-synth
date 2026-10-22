; control_counts.s -- the control program's loop counts for the chip check (#236)
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; In place of counts.s: the firmware's own layout (counts.s), so `csp match`
; checks the program the chip really runs. run_count.s's two rows fit because
; the layout leaves room under the pass's limit of 1472 cycles.
        .equ   CHANNEL_COUNT, 16
        .equ   VOICE_COUNT, 32
        .equ   SAWS_A_HALF, 1
        .equ   SQUARES_A_HALF, 1
        .equ   TRIANGLES_A_HALF, 1
        .equ   SINES_A_HALF, 1
