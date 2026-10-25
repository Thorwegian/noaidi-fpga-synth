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

        .equ   SAWS_A_HALF, 1
        .equ   SQUARES_A_HALF, 1
        .equ   TRIANGLES_A_HALF, 1
        .equ   SINES_A_HALF, 1

; One of each shape a half, so a half holds every waveform and the firmware
; places an LFO on the record of the preset's shape (app/main/render.cpp lfo():
; the saw at the pool's start, the square after the saws, and so on, and the
; channel reads that record). A half carries two LFOs at most — the synth is
; omni, one channel, two LFOs — so one slot of a shape is enough.
;
; How few records a half holds matters more than how the shapes are split into
; loops. A vector loop of n elements keeps a dependent pair of rows
; ceil(latency / n) rows apart, so short loops stall more per dependency; but
; four records stall far less in total than twelve do, however they are
; grouped. Measured at a result latency of 9 with 16 channels and 32 voices,
; both halves every pass (#268), the envelopes' stages the firmware's (#267);
; the pass is 3008 cycles since the 24 kHz pass (#268), 1472 before it:
;   one of each shape (four a half)    1460 cycles
;   6 squares and 6 sines              1446
;   3 of each shape (twelve a half)    1490
; Issue #237 moved the per-preset shape into the firmware; this is its layout.
