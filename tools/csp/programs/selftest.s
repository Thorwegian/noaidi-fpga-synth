; selftest.s -- what the firmware runs once at boot, to see that the chip does
; what the model says
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; After map.s. Scalar code only (#235): instructions that sit in dependent
; chains, worked a pass at a time into registers of their own, and counters
; that follow the pass counter's low bit through ANDXOR, SHIFT and IDX. The
; firmware reads them back through the probe and compares:
; engine_selftest.cpp. The schedule the assembler lays out is part of what
; is tested: the chip runs the rows as placed, with no interlock, so a wrong
; latency shows as a wrong result. Only registers the control program does
; not keep anything in are used (0x062 … 0x06F and 0x100 … 0x115).

        .reg   RES_PASS_BIT, 0x062      ; the pass counter's low bit
        .reg   RES_HALF,     0x064      ; the half's choice, 0 or 8
        .reg   RES_CHAIN,    0x066      ; 0x4000 (half 0) or 0x808 (half 1)
        .reg   RES_ABS,      0x068      ; |−4.0| = 4.0
        .reg   RES_MAC,      0x06A      ; 4.0 × 0.125 = 0.5
        .reg   RES_ADD3,     0x06C      ; 0.5 − 4.0 = −3.5
        .reg   RES_SEL,      0x06E      ; the select after a compare
        .reg   TABLE_0,      0x063      ; two words, eight apart, as the LFOs' two sets
        .reg   TABLE_1,      0x06B
        .equ   TABLE,        0x063
        .reg   TABLE_READ,   0x065

        ANDXOR  RES_PASS_BIT, 0, PASS, =#1
        ANDXOR  RES_HALF, 0, PASS, =#1
        SHIFT   RES_HALF, RES_HALF, =#3
        ADD3    TABLE_0, 0, ONE, ZERO       ; one immediate a word: the other operand is register 0
        ADD3    TABLE_1, 0, EIGHTH, ZERO
        IDX     j, =#TABLE, RES_HALF
        MAC     TABLE_READ, 0, [j+0], ONE
        ADD3    RES_CHAIN, 0, RES_HALF, TABLE_READ
        ABS     RES_ABS, MINUS_FOUR
        MAC     RES_MAC, 0, RES_ABS, EIGHTH
        ADD3    RES_ADD3, 0, RES_MAC, MINUS_FOUR
        CMP     ZERO, MINUS_FOUR, ZERO
        SEL     RES_SEL, TABLE_0, EIGHTH    ; negative: Y, 0.125

; Counts that do not depend on when the firmware looks: over every pass the
; test runs, how many passes there were, how many had the pass counter's low
; bit set, and in how many of those the half's choice and the table read
; (which come from that bit through ANDXOR, SHIFT and IDX) said "second". The
; firmware reads them twice, some milliseconds apart, and compares the
; differences: the second two must equal the first.
        .reg   COUNT_TOTAL,      0x100
        .reg   COUNT_ODD,        0x102
        .reg   COUNT_HALF_ODD,   0x104
        .reg   COUNT_CHAIN_ODD,  0x106
        .reg   COUNT_PASSES,     0x10E      ; wraps: one a pass, whatever the capture's length
        .reg   PASS_VIA_LOGIC,   0x112      ; the pass counter copied through the logic unit (fabric only)…
        .reg   PASS_VIA_DSP,     0x113      ; …and through the multiply-add (the DSP), the two an aligned pair
        .reg   PASS_VIA_LOGIC_A, 0x114      ; two more copies through the logic unit, a pair of their own
        .reg   PASS_VIA_LOGIC_B, 0x115
        .reg   ONE_RAW,          0x110      ; 1.0, for MACW's product of 1 raw step
        .reg   TEST_BIT,         0x108
        .reg   TEST_HALF,        0x10A
        .reg   TEST_CHAIN,       0x10C

        ; A counter that wraps, for a capture of any length: the other counters
        ; saturate at the largest word after 2.7 s, which the firmware's reads of
        ; differences do not mind. The probe's pair at COUNT_PASSES, streamed over
        ; S/PDIF (spdif_capture.py stream --probe-counter), must step once a pass.
        ADD3    ONE_RAW, 0, =1.0, ZERO
        MACW    COUNT_PASSES, COUNT_PASSES, ONE_RAW, =#1
        ; Copies of the pass counter, in aligned pairs the firmware's probe reads from
        ; one pass: the console's csp-pairwatch reads a pair thousands of times at a
        ; raised clock and counts the reads whose halves disagree. The first pair
        ; counts the multiply-add's misses (against the logic unit's copy), the
        ; second the logic unit's own. Each copy is one row with no chain.
        ANDXOR  PASS_VIA_LOGIC, 0, PASS, =#-1       ; PASS & all ones: the logic unit
        MAC     PASS_VIA_DSP, 0, PASS, =1.0         ; PASS × 1.0: the multiply-add
        ANDXOR  PASS_VIA_LOGIC_A, 0, PASS, =#-1
        ANDXOR  PASS_VIA_LOGIC_B, 0, PASS, =#-1
        ADD3    COUNT_TOTAL, COUNT_TOTAL, =#1, ZERO
        ANDXOR  TEST_BIT, 0, PASS, =#1
        ADD3    COUNT_ODD, COUNT_ODD, TEST_BIT, ZERO
        ADD3    TEST_HALF, 0, RES_HALF, ZERO
        SHIFT   TEST_HALF, TEST_HALF, =#-3
        ADD3    COUNT_HALF_ODD, COUNT_HALF_ODD, TEST_HALF, ZERO
        ANDXOR  TEST_CHAIN, 0, RES_CHAIN, =#8
        SHIFT   TEST_CHAIN, TEST_CHAIN, =#-3
        ADD3    COUNT_CHAIN_ODD, COUNT_CHAIN_ODD, TEST_CHAIN, ZERO
