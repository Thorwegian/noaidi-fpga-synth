; counts.s -- the loop counts the program is generated with
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; After map.s. Every loop has a fixed count (docs/csp2_isa.md section 5),
; so how many LFOs of each shape a half holds is a number in the program,
; not a register: the firmware's generator (#237) writes it with the
; program. Until then, this file is the one place the numbers live; the
; tests assemble the program with their own. The shapes of a half add up
; to at most LFOS_A_HALF (map.s), and i walks the half's records in the
; order saws, squares, triangles, sines.

        .equ   SAWS_A_HALF, 3
        .equ   SQUARES_A_HALF, 3
        .equ   TRIANGLES_A_HALF, 3
        .equ   SINES_A_HALF, 3
