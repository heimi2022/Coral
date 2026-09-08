`timescale 1ns/1ps

// 27 位分级树形前导零编码器。
// 输入非零时输出最高有效 1 前的零数量；输入全零时输出 27。
module lzd_tree_27 (
    input  logic [26:0] value_i,
    output logic [4:0]  count_o
);
    logic [31:0] level0;
    logic [15:0] level1;
    logic [7:0]  level2;
    logic [3:0]  level3;
    logic [1:0]  level4;
    logic        level0_hi;
    logic        level1_hi;
    logic        level2_hi;
    logic        level3_hi;
    logic [4:0]  zero_base1;
    logic [4:0]  zero_base2;
    logic [4:0]  zero_base3;
    logic [4:0]  zero_base4;
    logic [4:0]  zero_tail;

    // 低 5 位补零，使原输入 bit[26:0] 映射到 level0 bit[31:5]。
    assign level0 = {value_i, 5'b0};
    assign level0_hi = |level0[31:16];
    assign level1 = level0_hi ? level0[31:16] : level0[15:0];
    assign level1_hi = |level1[15:8];
    assign level2 = level1_hi ? level1[15:8] : level1[7:0];
    assign level2_hi = |level2[7:4];
    assign level3 = level2_hi ? level2[7:4] : level2[3:0];
    assign level3_hi = |level3[3:2];
    assign level4 = level3_hi ? level3[3:2] : level3[1:0];

    // 直接累计前导零数量，避免最后再做 31-index 减法。
    assign zero_base1 = level0_hi ? 5'd0 : 5'd16;
    assign zero_base2 = zero_base1 + (level1_hi ? 5'd0 : 5'd8);
    assign zero_base3 = zero_base2 + (level2_hi ? 5'd0 : 5'd4);
    assign zero_base4 = zero_base3 + (level3_hi ? 5'd0 : 5'd2);
    assign zero_tail  = level4[1] ? 5'd0 :
                        level4[0] ? 5'd1 : 5'd2;
    assign count_o = (value_i == 27'd0) ? 5'd27 :
                     zero_base4 + zero_tail;
endmodule

// 27 位减法前导零预测器。
// 预测向量直接由两个减数生成，不依赖减法器结果。预测的左移量可能
// 比真实值少 1，第 3 级会检查规格化隐藏位并完成一位校正。
module lza_sub_27 (
    input  logic [26:0] large_i,
    input  logic [26:0] small_i,
    output logic [4:0]  count_o
);
    logic [26:0] equal_w;
    logic [26:0] greater_w;
    logic [26:0] smaller_w;
    logic [26:0] predict_w;

    assign equal_w   = ~(large_i ^ small_i);
    assign greater_w = large_i & ~small_i;
    assign smaller_w = ~large_i & small_i;

    genvar bit_idx;
    generate
        for (bit_idx = 0; bit_idx < 27; bit_idx = bit_idx + 1) begin : g_lza_predict
            if (bit_idx == 26) begin : g_top
                assign predict_w[bit_idx] =
                    (greater_w[bit_idx] && !smaller_w[bit_idx-1]) ||
                    (smaller_w[bit_idx] && !greater_w[bit_idx-1]);
            end else if (bit_idx == 0) begin : g_bottom
                assign predict_w[bit_idx] = greater_w[bit_idx] ||
                                            smaller_w[bit_idx];
            end else begin : g_middle
                assign predict_w[bit_idx] =
                    (equal_w[bit_idx+1] &&
                     ((greater_w[bit_idx] && !smaller_w[bit_idx-1]) ||
                      (smaller_w[bit_idx] && !greater_w[bit_idx-1]))) ||
                    (!equal_w[bit_idx+1] &&
                     ((smaller_w[bit_idx] && !smaller_w[bit_idx-1]) ||
                      (greater_w[bit_idx] && !greater_w[bit_idx-1])));
            end
        end
    endgenerate

    lzd_tree_27 u_predict_encoder (
        .value_i ( predict_w ),
        .count_o ( count_o   )
    );
endmodule

// FP32 : 1 位符号 + 8 位阶码 + 23 位尾数。
//
// 改进型单路径浮点加法器：
//   第 1 拍：解包、特殊值识别、按有效阶码和尾数选择大小操作数；
//   第 2 拍：小尾数对阶，FPPA 同时生成 f_inter0/f_inter1，GRS 选择结果；
//   第 3 拍：校正 LZA 预测、规格化、指数调整和打包。
//
// 与基本单路径结构的区别：
//   1. FPPA 位于主尾数加法之后、规格化之前；
//   2. f_inter0 和 f_inter1 由 GRS 选择，不再在 Normalize 后串接 Round；
//   3. 指数同时形成 E_tmp 和 E_tmp+1，删除后置 Increment 数据路径。
module fp32_add (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_i,
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    output logic        valid_o,
    output logic [31:0] sum_o,
    output logic        invalid_o,
    output logic        overflow_o,
    output logic        underflow_o
);

    function automatic [26:0] shift_right_jam_27;
        input [26:0] value_i;
        input [5:0]  shift_i;
        integer idx;
        reg [26:0] shifted_value;
        reg        sticky_value;
        begin
            shifted_value = '0;
            sticky_value  = 1'b0;
            for (idx = 0; idx < 27; idx = idx + 1) begin
                if (idx < shift_i)
                    sticky_value = sticky_value | value_i[idx];
                if ((idx + shift_i) < 27)
                    shifted_value[idx] = value_i[idx + shift_i];
            end
            shifted_value[0] = shifted_value[0] | sticky_value;
            shift_right_jam_27 = shifted_value;
        end
    endfunction

    // 29 位版本的右移并 sticky，用于规格化后的次正规对齐。
    function automatic [28:0] shift_right_jam_29;
        input [28:0] value_i;
        input [5:0]  shift_i;
        integer idx;
        reg [28:0] shifted_value;
        reg        sticky_value;
        begin
            shifted_value = '0;
            sticky_value  = 1'b0;
            for (idx = 0; idx < 29; idx = idx + 1) begin
                if (idx < shift_i)
                    sticky_value = sticky_value | value_i[idx];
                if ((idx + shift_i) < 29)
                    shifted_value[idx] = value_i[idx + shift_i];
            end
            shifted_value[0] = shifted_value[0] | sticky_value;
            shift_right_jam_29 = shifted_value;
        end
    endfunction

    // ------------------------------------------------------------------
    // 第 1 级：解包、分类、比较有效操作数大小。
    // ------------------------------------------------------------------
    logic        a_sign_w, b_sign_w;
    logic [7:0]  a_exp_w, b_exp_w;
    logic [22:0] a_frac_w, b_frac_w;
    logic [8:0]  a_eff_exp_w, b_eff_exp_w;
    logic [23:0] a_sig_w, b_sig_w;
    logic        a_mag_ge_b_w;
    logic [8:0]  exp_distance_w;

    logic        s1_valid;
    logic        s1_a_zero, s1_b_zero;
    logic        s1_a_inf, s1_b_inf;
    logic        s1_a_nan, s1_b_nan;
    logic        s1_a_snan, s1_b_snan;
    logic        s1_a_sign, s1_b_sign;
    logic [7:0]  s1_a_exp, s1_b_exp;
    logic [22:0] s1_a_frac, s1_b_frac;
    logic        s1_large_sign, s1_small_sign;
    logic [8:0]  s1_large_exp;
    logic [23:0] s1_large_sig, s1_small_sig;
    logic [5:0]  s1_align_dist;

    assign a_sign_w = a_i[31];
    assign b_sign_w = b_i[31];
    assign a_exp_w  = a_i[30:23];
    assign b_exp_w  = b_i[30:23];
    assign a_frac_w = a_i[22:0];
    assign b_frac_w = b_i[22:0];

    // 次正规数使用有效阶码 1，但不补隐藏位。
    assign a_eff_exp_w = (a_exp_w == 8'd0) ? 9'd1 : {1'b0, a_exp_w};
    assign b_eff_exp_w = (b_exp_w == 8'd0) ? 9'd1 : {1'b0, b_exp_w};
    assign a_sig_w = {(a_exp_w != 8'd0), a_frac_w};
    assign b_sig_w = {(b_exp_w != 8'd0), b_frac_w};

    // 指数相同还要比较尾数，保证后续异号减法始终为大数减小数。
    assign a_mag_ge_b_w = (a_eff_exp_w > b_eff_exp_w) ||
                          ((a_eff_exp_w == b_eff_exp_w) &&
                           (a_sig_w >= b_sig_w));
    assign exp_distance_w = (a_eff_exp_w >= b_eff_exp_w) ?
                            (a_eff_exp_w - b_eff_exp_w) :
                            (b_eff_exp_w - a_eff_exp_w);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid      <= 1'b0;
            s1_a_zero     <= 1'b0;
            s1_b_zero     <= 1'b0;
            s1_a_inf      <= 1'b0;
            s1_b_inf      <= 1'b0;
            s1_a_nan      <= 1'b0;
            s1_b_nan      <= 1'b0;
            s1_a_snan     <= 1'b0;
            s1_b_snan     <= 1'b0;
            s1_a_sign     <= 1'b0;
            s1_b_sign     <= 1'b0;
            s1_a_exp      <= '0;
            s1_b_exp      <= '0;
            s1_a_frac     <= '0;
            s1_b_frac     <= '0;
            s1_large_sign <= 1'b0;
            s1_small_sign <= 1'b0;
            s1_large_exp  <= '0;
            s1_large_sig  <= '0;
            s1_small_sig  <= '0;
            s1_align_dist <= '0;
        end else begin
            s1_valid  <= valid_i;
            s1_a_zero <= (a_exp_w == 8'd0) && (a_frac_w == '0);
            s1_b_zero <= (b_exp_w == 8'd0) && (b_frac_w == '0);
            s1_a_inf  <= (a_exp_w == 8'hff) && (a_frac_w == '0);
            s1_b_inf  <= (b_exp_w == 8'hff) && (b_frac_w == '0);
            s1_a_nan  <= (a_exp_w == 8'hff) && (a_frac_w != '0);
            s1_b_nan  <= (b_exp_w == 8'hff) && (b_frac_w != '0);
            s1_a_snan <= (a_exp_w == 8'hff) && (a_frac_w != '0) && !a_frac_w[22];
            s1_b_snan <= (b_exp_w == 8'hff) && (b_frac_w != '0) && !b_frac_w[22];
            s1_a_sign <= a_sign_w;
            s1_b_sign <= b_sign_w;
            s1_a_exp  <= a_exp_w;
            s1_b_exp  <= b_exp_w;
            s1_a_frac <= a_frac_w;
            s1_b_frac <= b_frac_w;

            s1_large_sign <= a_mag_ge_b_w ? a_sign_w : b_sign_w;
            s1_small_sign <= a_mag_ge_b_w ? b_sign_w : a_sign_w;
            s1_large_exp  <= (a_eff_exp_w >= b_eff_exp_w) ?
                             a_eff_exp_w : b_eff_exp_w;
            s1_large_sig  <= a_mag_ge_b_w ? a_sig_w : b_sig_w;
            s1_small_sig  <= a_mag_ge_b_w ? b_sig_w : a_sig_w;
            s1_align_dist <= (exp_distance_w > 9'd27) ?
                             6'd27 : exp_distance_w[5:0];
        end
    end

    // ------------------------------------------------------------------
    // 第 2 级：对阶、主尾数 FPPA 和 GRS 选择。
    // ------------------------------------------------------------------
    logic [26:0] s2_small_aligned_w;
    logic [26:0] s2_small_operand_w;
    logic [28:0] s2_large_ext_w;
    logic [28:0] s2_small_ext_w;
    logic [28:0] s2_inter0_w;
    logic [28:0] s2_inter1_w;
    logic [25:0] s2_inter0_upper_w;
    logic [25:0] s2_inter1_upper_w;
    logic [28:0] s2_left_round_inter_w;
    logic [28:0] s2_selected_inter_d;
    logic        s2_result_sign_w;
    logic [4:0]  s2_lza_count_w;
    logic [4:0]  s2_lz_pred_w;
    logic        s2_right_norm_pred_w;
    logic        s2_guard_w;
    logic        s2_round_w;
    logic        s2_sticky_w;
    logic        s2_lsb_w;
    logic        s2_round_up_w;
    logic        s2_discarded_w;
    logic        s2_is_r1_w;
    logic        s2_need_left_norm_w;
    logic        round_up_r1_w;
    logic        round_up_n0_w;
    logic        round_up_l_w;
    logic        l_r1_w, g_r1_w, r_r1_w, s_r1_w;
    logic        l_n0_w, g_n0_w, r_n0_w, s_n0_w;
    logic        l_l_w,  g_l_w,  r_l_w,  s_l_w;

    logic        s2_valid;
    logic        s2_a_zero, s2_b_zero;
    logic        s2_a_inf, s2_b_inf;
    logic        s2_a_nan, s2_b_nan;
    logic        s2_a_snan, s2_b_snan;
    logic        s2_a_sign, s2_b_sign;
    logic [7:0]  s2_a_exp, s2_b_exp;
    logic [22:0] s2_a_frac, s2_b_frac;
    logic [8:0]  s2_large_exp;
    logic        s2_large_sign;
    logic [28:0] s2_selected_inter_q;
    logic        s2_result_sign_q;
    logic        s2_discarded_q;
    logic [4:0]  s2_lz_pred_q;
    logic        s2_right_norm_pred_q;

    assign s2_small_aligned_w = shift_right_jam_27(
        {s1_small_sig, 3'b000}, s1_align_dist);
    assign s2_large_ext_w = {2'b00, s1_large_sig, 3'b000};

    // 异号运算使用大尾数减小尾数，即大尾数加小尾数的二补码。
    // 必须先扩展到 29 位再取二补码；27 位对齐尾数可能占用 bit[26]，
    // 不能直接把 27 位结果按符号数扩展，否则会误判最高位为符号位。
    assign s2_small_operand_w = s2_small_aligned_w;
    assign s2_small_ext_w = (s1_large_sign == s1_small_sign) ?
                            {2'b00, s2_small_operand_w} :
                            (~{2'b00, s2_small_operand_w} + 29'd1);

    // 减法 LZA 与 FPPA 并行：直接根据两个对阶尾数预测前导零数量。
    // 同号加法不会发生多位抵消，因此其左移预测固定为 0。
    lza_sub_27 u_lza_sub (
        .large_i ( s2_large_ext_w[26:0] ),
        .small_i ( s2_small_aligned_w    ),
        .count_o ( s2_lza_count_w        )
    );
    assign s2_lz_pred_w = (s1_large_sign != s1_small_sign) ?
                           s2_lza_count_w : 5'd0;

    // 右规判断必须基于最终选出的 f_round。
    // 如果舍入进位使 f_inter1 产生 bit[27]，这里也能正确检测到右规。
    // s2_selected_inter_d 只依赖 f_inter0 的 GRS 和 FPPA 两路结果，
    // 不依赖本信号，因此不会形成组合反馈环。
    assign s2_right_norm_pred_w = s2_selected_inter_d[27];

    // 根据未舍入结果判断三种规格化方向：
    //   bit[27]=1：加法产生进位，需要右规 1 位；
    //   bit[27:26]=00：发生抵消，需要左规；
    //   其它情况：无需规格化移位。
    assign s2_is_r1_w = s2_inter0_w[27];
    assign s2_need_left_norm_w = !s2_inter0_w[27] &&
                                 !s2_inter0_w[26];

    // 大尾数低 3 位恒为 0，因此低 3 位不会向 bit[3] 产生进位。
    // FPPA 只计算高 26 位，并用同一套前缀树同时得到 S 和 S+1；
    // 拼回低 3 位后，对应完整 29 位结果 S 和 S+(1<<3)。
    FPPA #(
        .WIDTH   ( 26 )
    ) u_inter_fppa (
        .x_i           ( s2_large_ext_w[28:3] ),
        .y_i           ( s2_small_ext_w[28:3] ),
        .sum_o         ( s2_inter0_upper_w    ),
        .sum_plus1_o   ( s2_inter1_upper_w    ),
        .carry_o       (               ),
        .carry_plus1_o (               )
    );

    assign s2_inter0_w = {s2_inter0_upper_w, s2_small_ext_w[2:0]};
    assign s2_inter1_w = {s2_inter1_upper_w, s2_small_ext_w[2:0]};

    // 左规 1 位时需要的是 S+4。利用并行产生的 S/S+8 局部构造：
    // 原 bit[2]=0 时只翻转 bit[2]；原 bit[2]=1 时，进位后的高位
    // 与 S+8 相同，同时将 bit[2] 清零，因此不需要额外加法器。
    assign s2_left_round_inter_w[28:3] = s2_inter0_w[2] ?
                                               s2_inter1_w[28:3] :
                                               s2_inter0_w[28:3];
    assign s2_left_round_inter_w[2]   = !s2_inter0_w[2];
    assign s2_left_round_inter_w[1:0] = s2_inter0_w[1:0];

    // R1：右规 1 位后，保留位为原 bit[4]。
    assign l_r1_w = s2_inter0_w[4];
    assign g_r1_w = s2_inter0_w[3];
    assign r_r1_w = s2_inter0_w[2];
    assign s_r1_w = s2_inter0_w[1] || s2_inter0_w[0];
    assign round_up_r1_w = g_r1_w && (r_r1_w || s_r1_w || l_r1_w);

    // N0：不移位时，保留位为原 bit[3]。
    assign l_n0_w = s2_inter0_w[3];
    assign g_n0_w = s2_inter0_w[2];
    assign r_n0_w = s2_inter0_w[1];
    assign s_n0_w = s2_inter0_w[0];
    assign round_up_n0_w = g_n0_w && (r_n0_w || s_n0_w || l_n0_w);

    // L：左规时按左移 1 位提取低位。
    // 如果实际左规超过 1 位，精确减法性质保证该路径不会舍入。
    assign l_l_w = s2_inter0_w[2];
    assign g_l_w = s2_inter0_w[1];
    assign r_l_w = s2_inter0_w[0];
    assign s_l_w = 1'b0;
    assign round_up_l_w = g_l_w && (r_l_w || s_l_w || l_l_w);

    // 选择当前方向对应的 GRS，供下溢判断使用。
    assign s2_guard_w  = s2_is_r1_w ? g_r1_w :
                         s2_need_left_norm_w ? g_l_w : g_n0_w;
    assign s2_round_w  = s2_is_r1_w ? r_r1_w :
                         s2_need_left_norm_w ? r_l_w : r_n0_w;
    assign s2_sticky_w = s2_is_r1_w ? s_r1_w :
                         s2_need_left_norm_w ? s_l_w : s_n0_w;
    assign s2_lsb_w    = s2_is_r1_w ? l_r1_w :
                         s2_need_left_norm_w ? l_l_w : l_n0_w;

    // 三种方向的 GRS 选择不依赖完整 LZD 编码结果。
    assign s2_round_up_w = s2_is_r1_w          ? round_up_r1_w :
                           s2_need_left_norm_w ? round_up_l_w  :
                                                  round_up_n0_w;
    // G/R/S 非零说明低位存在被舍弃的信息，仅供下溢判断使用。
    assign s2_discarded_w = s2_guard_w || s2_round_w || s2_sticky_w;

    // N0 和 R1 触发舍入时都可以直接选择固定的 S+8：
    // R1 的 Guard=bit[3]=1，S+8 会自然向真正的 LSB bit[4] 进位。
    // 左规触发舍入时选择局部构造的 S+4。
    assign s2_selected_inter_d = !s2_round_up_w ? s2_inter0_w :
                                 s2_need_left_norm_w ?
                                 s2_left_round_inter_w : s2_inter1_w;
    assign s2_result_sign_w = (s2_inter0_w == '0) ? 1'b0 : s1_large_sign;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid      <= 1'b0;
            s2_a_zero     <= 1'b0;
            s2_b_zero     <= 1'b0;
            s2_a_inf      <= 1'b0;
            s2_b_inf      <= 1'b0;
            s2_a_nan      <= 1'b0;
            s2_b_nan      <= 1'b0;
            s2_a_snan     <= 1'b0;
            s2_b_snan     <= 1'b0;
            s2_a_sign     <= 1'b0;
            s2_b_sign     <= 1'b0;
            s2_a_exp      <= '0;
            s2_b_exp      <= '0;
            s2_a_frac     <= '0;
            s2_b_frac     <= '0;
            s2_large_exp  <= '0;
            s2_large_sign <= 1'b0;
            s2_selected_inter_q <= '0;
            s2_result_sign_q    <= 1'b0;
            s2_discarded_q     <= 1'b0;
            s2_lz_pred_q        <= '0;
            s2_right_norm_pred_q<= 1'b0;
        end else begin
            s2_valid      <= s1_valid;
            s2_a_zero     <= s1_a_zero;
            s2_b_zero     <= s1_b_zero;
            s2_a_inf      <= s1_a_inf;
            s2_b_inf      <= s1_b_inf;
            s2_a_nan      <= s1_a_nan;
            s2_b_nan      <= s1_b_nan;
            s2_a_snan     <= s1_a_snan;
            s2_b_snan     <= s1_b_snan;
            s2_a_sign     <= s1_a_sign;
            s2_b_sign     <= s1_b_sign;
            s2_a_exp      <= s1_a_exp;
            s2_b_exp      <= s1_b_exp;
            s2_a_frac     <= s1_a_frac;
            s2_b_frac     <= s1_b_frac;
            s2_large_exp  <= s1_large_exp;
            s2_large_sign <= s1_large_sign;
            s2_selected_inter_q <= s2_selected_inter_d;
            s2_result_sign_q    <= s2_result_sign_w;
            s2_discarded_q     <= s2_discarded_w;
            s2_lz_pred_q        <= s2_lz_pred_w;
            s2_right_norm_pred_q<= s2_right_norm_pred_w;
        end
    end

    // ------------------------------------------------------------------
    // 第 3 级：使用第 2 级预测的 z，完成 Normalize、Exponent Adjust 和打包。
    // ------------------------------------------------------------------
    logic        s3_sum_sign_w;
    logic [28:0] s3_sum_mag_w;
    logic [4:0]  s3_lzc_w;
    logic [5:0]  s3_left_shift_w;
    logic [28:0] s3_lza_shifted_w;
    logic        s3_lza_correct_w;
    logic [28:0] s3_normalized_ext_w;
    logic signed [11:0] s3_exp_tmp1_w;
    logic signed [11:0] s3_exp_tmp2_w;
    logic signed [11:0] s3_normalized_exp_w;
    logic [28:0] s3_denorm_ext_w;
    logic [5:0]  s3_denorm_shift_w;
    logic signed [11:0] s3_result_exp_w;
    logic [23:0] s3_result_mantissa_w;
    logic [31:0] s3_finite_sum_w;
    logic        s3_finite_overflow_w;
    logic        s3_finite_underflow_w;
    logic [31:0] s3_sum_w;
    logic        s3_invalid_w;
    logic        s3_overflow_w;
    logic        s3_underflow_w;
    logic        s3_discarded_w;
    logic        s3_need_right_norm_w;
    logic        s3_same_sign_subnormal_pair_w;
    logic [31:0] s3_subnormal_pair_sum_w;

    assign s3_sum_sign_w = s2_result_sign_q;

    assign s3_sum_mag_w = s2_selected_inter_q;
    // 第 2 级已经完成 LZA，当前级使用锁存的预测结果进行规格化。
    assign s3_need_right_norm_w = s2_right_norm_pred_q;
    // 同号加法不需要 LZA；异号相减可能需要多位左规。
    assign s3_lzc_w = !s3_need_right_norm_w ?
                      s2_lz_pred_q : 5'd0;

    // LZA 预测值可能比真实前导零数少 1。先按预测值左移，再检查
    // 隐藏位 bit[26]；若仍为 0，则额外左移一位并同步修正指数。
    assign s3_lza_shifted_w = s3_sum_mag_w << s3_lzc_w;
    assign s3_lza_correct_w = !s3_need_right_norm_w &&
                              (s2_a_sign != s2_b_sign) &&
                              (s3_sum_mag_w != '0) &&
                              !s3_lza_shifted_w[26];
    assign s3_left_shift_w = {1'b0, s3_lzc_w} +
                             {{5{1'b0}}, s3_lza_correct_w};

    // f_round 最高位为 1 时右规一位，否则按 LZA 预测及校正量左规。
    assign s3_normalized_ext_w = s3_need_right_norm_w ?
                                 shift_right_jam_29(s3_sum_mag_w, 6'd1) :
                                 (s3_lza_correct_w ?
                                  (s3_lza_shifted_w << 1) :
                                   s3_lza_shifted_w);
    // E_tmp1 对应左规/不规，E_tmp2 对应加法溢出后的右规。
    assign s3_exp_tmp1_w = $signed({3'b000, s2_large_exp}) -
                           $signed({6'b0, s3_left_shift_w});
    assign s3_exp_tmp2_w = $signed({3'b000, s2_large_exp}) + 12'sd1;
    assign s3_normalized_exp_w = s3_need_right_norm_w ?
                                 s3_exp_tmp2_w : s3_exp_tmp1_w;

    // 指数不大于 0 时，把规格化结果右移到次正规数位置，并保留 sticky。
    assign s3_denorm_shift_w = (s3_normalized_ext_w != '0) && (s3_normalized_exp_w <= 0) ?
                               (6'd1 - s3_normalized_exp_w) : 6'd0;
    assign s3_denorm_ext_w = (s3_normalized_ext_w != '0) && (s3_normalized_exp_w <= 0) ?
                             shift_right_jam_29(s3_normalized_ext_w,
                                                s3_denorm_shift_w) :
                             s3_normalized_ext_w;
    assign s3_result_exp_w = s3_normalized_exp_w;
    assign s3_result_mantissa_w = s3_denorm_ext_w[26:3];

    assign s3_finite_overflow_w = (s3_result_exp_w >= 12'sd255);
    assign s3_discarded_w = s2_discarded_q ||
                            s3_denorm_ext_w[2] ||
                            s3_denorm_ext_w[1] ||
                            s3_denorm_ext_w[0];
    assign s3_finite_underflow_w = (s3_result_exp_w <= 12'sd0) &&
                                   !s3_result_mantissa_w[23] &&
                                   s3_discarded_w;
    // 两个同号次正规数具有相同的量化单位，其和可以直接精确打包。
    assign s3_same_sign_subnormal_pair_w = (s2_a_exp == 8'd0) &&
                                            (s2_b_exp == 8'd0) &&
                                            (s2_a_sign == s2_b_sign);
    assign s3_subnormal_pair_sum_w =
        {s3_sum_sign_w,
         s3_sum_mag_w[26] ? 8'd1 : 8'd0,
         s3_sum_mag_w[25:3]};

    assign s3_finite_sum_w = s3_same_sign_subnormal_pair_w ?
                             s3_subnormal_pair_sum_w :
                             s3_finite_overflow_w ?
                             {s3_sum_sign_w, 8'hff, 23'd0} :
                             (s3_result_mantissa_w == '0) ?
                             {s3_sum_sign_w, 31'd0} :
                             ((s3_result_exp_w <= 12'sd0) &&
                              !s3_result_mantissa_w[23]) ?
                             {s3_sum_sign_w, 8'd0,
                              s3_result_mantissa_w[22:0]} :
                             {s3_sum_sign_w, s3_result_exp_w[7:0],
                              s3_result_mantissa_w[22:0]};

    // 特殊值和零操作数优先覆盖有限数通路。
    assign s3_sum_w = (s2_a_nan || s2_b_nan) ?
                      (s2_a_nan ?
                       {s2_a_sign, 8'hff, (s2_a_frac | 23'h400000)} :
                       {s2_b_sign, 8'hff, (s2_b_frac | 23'h400000)}) :
                      (s2_a_inf && s2_b_inf &&
                       (s2_a_sign != s2_b_sign)) ? 32'h7fc00000 :
                      s2_a_inf ? {s2_a_sign, 8'hff, 23'd0} :
                      s2_b_inf ? {s2_b_sign, 8'hff, 23'd0} :
                      (s2_a_zero && s2_b_zero) ?
                      {s2_a_sign && s2_b_sign, 31'd0} :
                      s2_a_zero ? {s2_b_sign, s2_b_exp, s2_b_frac} :
                      s2_b_zero ? {s2_a_sign, s2_a_exp, s2_a_frac} :
                      s3_finite_sum_w;
    assign s3_invalid_w = (s2_a_nan || s2_b_nan) ?
                          (s2_a_snan || s2_b_snan) :
                          (s2_a_inf && s2_b_inf &&
                           (s2_a_sign != s2_b_sign));
    assign s3_overflow_w = (s2_a_nan || s2_b_nan || s2_a_inf ||
                            s2_b_inf || s2_a_zero || s2_b_zero) ?
                           1'b0 : s3_finite_overflow_w;
    assign s3_underflow_w = (s2_a_nan || s2_b_nan || s2_a_inf ||
                             s2_b_inf || s2_a_zero || s2_b_zero) ?
                            1'b0 : s3_finite_underflow_w;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_o     <= 1'b0;
            sum_o       <= '0;
            invalid_o   <= 1'b0;
            overflow_o  <= 1'b0;
            underflow_o <= 1'b0;
        end else begin
            valid_o     <= s2_valid;
            sum_o       <= s3_sum_w;
            invalid_o   <= s3_invalid_w;
            overflow_o  <= s3_overflow_w;
            underflow_o <= s3_underflow_w;
        end
    end

endmodule
