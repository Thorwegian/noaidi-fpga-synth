; counts.s -- the loop counts the program is generated with
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; After map.s. Every loop has a fixed count (docs/csp2_isa.md section 5),
; so how many channels and voices the program runs and how many LFOs of
; each shape a half holds are numbers in the program, not registers: the
; firmware's generator (#237) writes them with the program. Until then,
; this file is the one place the numbers live; the tests assemble the
; program with their own. The firmware reads them from the generated header
; (app/main/csp/control_program.hpp) and wires every channel and voice the
; loops run, whether it uses it or not: a loop runs every element with
; whatever its registers hold. The shapes of a half add up to at most
; LFOS_A_HALF (map.s), and i walks the half's records in the order saws,
; squares, triangles, sines.

        .equ   CHANNEL_COUNT, 16
        .equ   VOICE_COUNT, 32

        .equ   SAWS_A_HALF, 0
        .equ   SQUARES_A_HALF, 6
        .equ   TRIANGLES_A_HALF, 0
        .equ   SINES_A_HALF, 6

; Six squares and six sines, because the Galaxy patch the sound is judged by
; (tools/lab/benchmark, #238) runs its two LFOs as pulses: LFO 1 on the pitch,
; LFO 2 on the pulse width. Why not three of each shape: a vector loop of n elements
; keeps a dependent pair of rows ceil(latency / n) rows apart, so four loops of
; three pay three rows for every dependency where one loop of twelve pays one.
; Measured at a result latency of 9 with 16 channels and 32 voices:
;   12 sines                   1433 cycles    fits (the limit is 1472)
;   6 squares and 6 sines      1467           fits
;   6 saws and 6 sines         1455           fits
;   3 of each shape            1487           does not
;   4 saws, 4 triangles, 4 sines   1497       does not
; The generator (#237) chooses the layout; the shapes it merges into one loop
; are its business, and SEL on a per-record shape word is one way to do it.
