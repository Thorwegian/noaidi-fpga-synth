//------------------------------------------------------------------------
// csp_alu.sv -- the CSP's execute datapath (#235)
//
// Copyright (c) 2026 Thor H. Linlokken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One row's arithmetic, bit-identical to tools/csp/processor.cpp. All
// sums happen in the accumulator's format, Q8.46 (54 bits): a word enters
// shifted left by 32, a wide by 14, a word x word product by 18, a word x
// wide product as it is. Results are truncated (arithmetic shift right,
// toward minus infinity) then saturated or wrapped to the destination.
// The core registers these outputs along the pipeline.
//------------------------------------------------------------------------
`default_nettype none
module csp_alu (
    input  wire [2:0]  unit,        // Unit
    input  wire [2:0]  writes,      // Writes
    input  wire [1:0]  a_source,    // ASource
    input  wire [2:0]  sub,         // the unit's sub-operation
    input  wire        y_wide,      // Y is a wide operand
    input  wire        wrap,        // MACW wraps instead of saturating
    input  wire [3:0]  cond,        // the word's condition
    input  wire [2:0]  flags,       // {negative, zero, overflow}

    // operands, already read and sign-extended to their widths
    input  wire [53:0] a_val,       // the A operand, Q8.46
    input  wire [17:0] x_word,      // Q4.14
    input  wire [17:0] y_word,      // Q4.14 when !y_wide
    input  wire [35:0] y_wide_val,  // Q4.32 when y_wide

    output logic [17:0] result_word,        // a word write's value
    output logic [35:0] result_wide,        // a pair write's value
    output logic [53:0] result_accumulator, // an accumulator write's value
    output logic        overflow,           // the reduction saturated
    output logic [2:0]  flags_out,          // {negative, zero, overflow}
    output logic [11:0] result_index,
    output logic        cond_holds
);

    import csp_pkg::*;

    localparam logic [2:0] UNIT_MULADD = 3'd1;
    localparam logic [2:0] UNIT_LOGIC  = 3'd2;
    localparam logic [2:0] UNIT_SHIFT  = 3'd3;

    localparam logic [2:0] WR_WORD  = 3'd1;
    localparam logic [2:0] WR_PAIR  = 3'd2;
    localparam logic [2:0] WR_ACC   = 3'd5;

    localparam logic [2:0] SUB_MAC    = 3'd0;
    localparam logic [2:0] SUB_INTERP = 3'd1;
    localparam logic [2:0] SUB_ADD3   = 3'd2;
    localparam logic [2:0] SUB_CMP    = 3'd3;
    localparam logic [2:0] SUB_ABS    = 3'd4;

    localparam logic [2:0] SUB_MIN    = 3'd0;
    localparam logic [2:0] SUB_MAX    = 3'd1;
    localparam logic [2:0] SUB_SEL    = 3'd2;
    localparam logic [2:0] SUB_ANDXOR = 3'd3;

    always_comb begin
        // ---- locals -----------------------------------------------------
        logic signed [53:0] xq, yq, product;
        logic signed [55:0] sum;
        logic signed [117:0] shifted, raw, red;
        logic [17:0] arith_word;
        logic [35:0] arith_wide;
        logic [53:0] arith_acc;
        logic       arith_overflow;
        logic [17:0] logic_word;
        logic       logic_is_flags;   // the logic op commits the flags

        // ---- the condition ----------------------------------------------
        unique case (cond[2:0])
            3'd0: cond_holds = 1'b1;
            3'd1: cond_holds = flags[2];
            3'd2: cond_holds = ~flags[2];
            3'd3: cond_holds = flags[1];
            3'd4: cond_holds = ~flags[1];
            3'd5: cond_holds = flags[0];
            default: cond_holds = 1'b0;
        endcase

        // ---- the operands widened to Q8.46 (54 bits) --------------------
        xq = $signed({{36{x_word[17]}}, x_word});
        yq = y_wide ? $signed({{18{y_wide_val[35]}}, y_wide_val})
                    : $signed({{36{y_word[17]}}, y_word});

        // ---- the product, Q8.46 -----------------------------------------
        // word x word: the 36-bit product shifted left 18. word x wide:
        // the 54-bit product as it is.
        if (y_wide) begin
            product = $signed({{36{x_word[17]}}, x_word}) * $signed({{18{y_wide_val[35]}}, y_wide_val});
        end else begin
            logic signed [35:0] ww;
            ww = $signed({{18{x_word[17]}}, x_word}) * $signed({{18{y_word[17]}}, y_word});
            product = {ww, 18'b0};
        end

        // ---- the multiply-add unit's sum, Q8.46 in 56 bits ---------------
        sum = '0;
        if (unit == UNIT_MULADD) begin
            unique case (sub)
                SUB_MAC:    sum = $signed({{2{a_val[53]}}, a_val}) + $signed({{2{product[53]}}, product});
                SUB_ADD3:   sum = $signed({{2{a_val[53]}}, a_val}) + $signed({{2{xq[53]}}, xq}) + $signed({{2{yq[53]}}, yq});
                SUB_CMP:    sum = $signed({{2{xq[53]}}, xq}) - $signed({{2{yq[53]}}, yq});
                SUB_ABS:    sum = (xq < 0) ? -$signed({{2{xq[53]}}, xq}) : $signed({{2{xq[53]}}, xq});
                SUB_INTERP: begin
                    // delta = saturate((Y - A) >> 14, 36); R = A + delta * X
                    logic signed [53:0] d_full;
                    logic signed [35:0] delta;
                    logic signed [53:0] dx_prod;
                    d_full = (yq - $signed(a_val)) >>> 14;
                    if ($signed(d_full) > 54'sd34359738367)      delta = 36'h7FFFFFFFF;
                    else if ($signed(d_full) < -54'sd34359738368) delta = 36'h800000000;
                    else                                         delta = d_full[35:0];
                    dx_prod = $signed({{18{delta[35]}}, delta}) * $signed({{36{x_word[17]}}, x_word});
                    sum = $signed({{2{a_val[53]}}, a_val}) + $signed({{2{dx_prod[53]}}, dx_prod});
                end
                default: sum = '0;
            endcase
        end

        // ---- the shift unit, full width ----------------------------------
        begin
            logic signed [6:0] count;
            logic signed [117:0] a_ext;
            a_ext = $signed({{64{a_val[53]}}, a_val});
            if ($signed(y_word) > 63)        count = 7'd63;
            else if ($signed(y_word) < -63)  count = -7'd63;
            else                             count = $signed(y_word[6:0]);
            shifted = (count >= 0) ? (a_ext <<< count) : (a_ext >>> (-count));
        end

        // ---- the value to reduce ----------------------------------------
        raw = (unit == UNIT_SHIFT) ? shifted : $signed({{62{sum[55]}}, sum});

        // ---- the reduction, saturated or wrapped -------------------------
        arith_word = '0; arith_wide = '0; arith_acc = '0; arith_overflow = 1'b0;
        unique case (writes)
            WR_ACC: begin
                if (sum[55:54] != {2{sum[53]}}) begin
                    arith_acc = sum[53] ? 54'h40000000000000 : 54'h3FFFFFFFFFFFFF;
                    arith_overflow = 1'b1;
                end else begin
                    arith_acc = sum[53:0];
                end
            end
            WR_PAIR: begin
                red = raw >>> 14;
                if (wrap) begin
                    arith_wide = red[35:0];
                end else if (red[117:36] != {82{red[35]}}) begin
                    arith_wide = red[35] ? 36'h800000000 : 36'h7FFFFFFFF;
                    arith_overflow = 1'b1;
                end else begin
                    arith_wide = red[35:0];
                end
            end
            default: begin   // WR_WORD
                red = raw >>> 32;
                if (wrap) begin
                    arith_word = red[17:0];
                end else if (red[117:18] != {100{red[17]}}) begin
                    arith_word = red[17] ? 18'h20000 : 18'h1FFFF;
                    arith_overflow = 1'b1;
                end else begin
                    arith_word = red[17:0];
                end
            end
        endcase

        // ---- the logic unit: word results --------------------------------
        logic_word = '0;
        logic_is_flags = 1'b0;
        if (unit == UNIT_LOGIC) begin
            logic signed [17:0] a_word;
            logic signed [53:0] a_reduced;
            a_reduced = $signed(a_val) >>> 32;
            if ($signed(a_reduced) > 54'sd131071)       a_word = 18'sh1FFFF;
            else if ($signed(a_reduced) < -54'sd131072) a_word = -18'sd131072;
            else                                        a_word = a_reduced[17:0];
            if (a_source == 2'd0) a_word = 18'sd0;

            unique case (sub)
                SUB_MIN:    logic_word = ($signed(x_word) < $signed(y_word)) ? x_word : y_word;
                SUB_MAX:    logic_word = ($signed(x_word) > $signed(y_word)) ? x_word : y_word;
                SUB_SEL:    logic_word = cond_holds ? y_word : x_word;
                SUB_ANDXOR: logic_word = (x_word & y_word) ^ a_word;
                default:    logic_word = '0;
            endcase
            // min, max and andxor commit the flags; sel does not
            logic_is_flags = (sub != SUB_SEL);
        end

        // ---- the outputs --------------------------------------------------
        if (unit == UNIT_LOGIC) begin
            result_word = logic_word;
        end else begin
            result_word = arith_word;
        end
        result_wide = arith_wide;
        result_accumulator = arith_acc;
        overflow = (unit == UNIT_LOGIC) ? 1'b0 : arith_overflow;

        if (unit == UNIT_LOGIC && logic_is_flags) begin
            flags_out[2] = result_word[17];
            flags_out[1] = (result_word == 18'b0);
            flags_out[0] = 1'b0;
        end else begin
            flags_out[2] = result_wide[35] | result_accumulator[53] | result_word[17];
            flags_out[1] = (result_wide == 36'b0) & (result_accumulator == 54'b0) & (result_word == 18'b0);
            flags_out[0] = overflow;
        end

        // ---- the index unit: i or j = X + Y, modulo 4096 ------------------
        result_index = x_word[11:0] + y_word[11:0];   // X + Y modulo 4096
    end

endmodule
`default_nettype wire
