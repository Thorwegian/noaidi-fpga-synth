; vector_back_to_back.s -- two vector loops in a row, each choosing by its elements' flags (#236)
;
; Copyright © 2026 Thor H. Linløkken <thj@thj.no>
; License: CERN-OHL-S v2
;
; The LFO program's shape: a loop of six elements whose last rows are a CMP
; and the SEL that reads it, then at once the next loop of six, the same. The
; first loop's last SELs are still in the pipeline when the second loop's row
; arrives, and read their elements' flags four cycles after they issue; the
; chip got element 3's wrong when the copies were cleared at the next loop's
; row (the control program's check, 0x0B7). The elements' X from the fill lie
; on both sides of the threshold.
;
; The registers every check shares, and the two rows at the top that count
; the passes run (RUN_COUNT wraps), so that `csp match` runs the model for
; exactly as many passes as the chip did:
        .reg A_, 0x060
        .reg B_, 0x061
        .reg C_, 0x062
        .reg D_, 0x063
        .wide W_, 0x064
        .wide V_, 0x066
        .reg S_, 0x068
        .reg T_, 0x069
        .block ITEM
        .field X, 1
        .field Y, 1
        .field Z, 1
        .field SPARE, 5
        .end
        .reg RUN_ONE, 0x3FD
        .reg RUN_COUNT, 0x3FE
        ADD3   RUN_ONE, 0, =1.0, ZERO
        MACW   RUN_COUNT, RUN_COUNT, RUN_ONE, =#1
            IDX    i, =#0x200, 0
            LOOP.vi end_a, =#6, =#8
            MACW   [i+Z], [i+Z], A_, =#4097         ; a phase: steps by A_ x 4097 and wraps
            CMP    ZERO, [i+Z], ZERO
            SEL    [i+Y], A_, B_                    ; negative: B_, else A_, by this element's flags
end_a:
            LOOP.vi end_b, =#6, =#8                 ; i goes on from the last element
            MACW   [i+Z], [i+Z], B_, =#2731
            CMP    ZERO, [i+Z], ZERO
            SEL    [i+Y], A_, B_
end_b:
