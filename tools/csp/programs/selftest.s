; selftest.s -- what the firmware runs once at boot, to see that the chip does
; what the model says
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; After map.s and lfo.s. The LFOs run as they do in the control program, and
; the code below them works the instructions that sit in dependent chains
; (the LFOs' own, and the half's choice from the pass counter) a pass at a
; time, into registers of its own. The firmware reads them back through the
; probe and compares: engine_selftest.cpp. Only registers the control program
; does not keep anything in are used (0x062 … 0x06F).

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
        MAC     TABLE_0, 0, ONE, ONE
        MAC     TABLE_1, 0, EIGHTH, ONE
        IDX     j, =#TABLE, RES_HALF
        MAC     TABLE_READ, 0, [j+BASE], ONE
        ADD3    RES_CHAIN, 0, RES_HALF, TABLE_READ
        ABS     RES_ABS, MINUS_FOUR
        MAC     RES_MAC, 0, RES_ABS, EIGHTH
        ADD3    RES_ADD3, 0, RES_MAC, MINUS_FOUR
        CMP     ZERO, MINUS_FOUR, ZERO
        SEL     RES_SEL, ONE, EIGHTH

; Counts that do not depend on when the firmware looks: over every pass the
; test runs, how many passes there were, how many had the pass counter's low
; bit set, and in how many of those the half's choice and the table read
; (which come from that bit through ANDXOR, SHIFT and IDX) said "second". The
; firmware reads them twice, some milliseconds apart, and compares the
; differences: the second two must equal the first.
        .const RAW_ONE, 0.00006103515625
        .reg   COUNT_TOTAL,      0x100
        .reg   COUNT_ODD,        0x102
        .reg   COUNT_HALF_ODD,   0x104
        .reg   COUNT_CHAIN_ODD,  0x106
        .reg   TEST_BIT,         0x108
        .reg   TEST_HALF,        0x10A
        .reg   TEST_CHAIN,       0x10C

        ADD3    COUNT_TOTAL, COUNT_TOTAL, RAW_ONE, ZERO
        ANDXOR  TEST_BIT, 0, PASS, =#1
        ADD3    COUNT_ODD, COUNT_ODD, TEST_BIT, ZERO
        ADD3    TEST_HALF, 0, RES_HALF, ZERO
        SHIFT   TEST_HALF, TEST_HALF, =#-3
        ADD3    COUNT_HALF_ODD, COUNT_HALF_ODD, TEST_HALF, ZERO
        ANDXOR  TEST_CHAIN, 0, RES_CHAIN, =#8
        SHIFT   TEST_CHAIN, TEST_CHAIN, =#-3
        ADD3    COUNT_CHAIN_ODD, COUNT_CHAIN_ODD, TEST_CHAIN, ZERO
