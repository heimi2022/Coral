`timescale 1ns/1ps

// MXINT8 点积与定制 C 格式的融合累加器。
//
// C Reg 中每个元素使用 32 bit 定制格式：
//   [31:24]：指数；[23]：符号；[22:0]：压缩后的尾数字段。
//
// 非零数的完整 25 bit 补码尾数为：
//   正数：01.fraction
//   负数：10.fraction
// 其中中间的隐藏位由符号决定，因此存储时省略。零使用全零编码，
// 不能参与隐藏位恢复或指数对齐。
//
// 数据通路为四拍：
//   第 1 拍：MX 点积规格化、C 解码和两个补码尾数对阶；
//   第 2 拍：FPPA 同时产生未舍入结果和预加舍入位的结果，并选择结果；
//   第 3 拍：补码规格化、前导零检测和可变左移；
//   第 4 拍：指数边界处理、结果格式压缩和写回。
//
// 本模块面向推理场景，只支持有限数和零，不处理次正规数、Inf、NaN。
module accumulaters #(
    parameter int TILE_COLS    = 32,
    parameter int PE_ACC_WIDTH = 21
) (
    input  logic                                         clk,
    input  logic                                         rst_n,

    input  logic [255:0]                                 a_scale_data_i,
    input  logic                                         a_scale_data_valid_i,
    input  logic [255:0]                                 b_scale_data_i,
    input  logic                                         b_scale_data_valid_i,

    input  logic                                         valid_i,
    input  logic [TILE_COLS * PE_ACC_WIDTH - 1 : 0]      add_pe_i,
    input  logic [TILE_COLS * 32 - 1 : 0]                add_rd_i,
    output logic                                         valid_o,
    output logic [TILE_COLS * 32 - 1 : 0]                sum_o
);

    // 格式指数保持 8 bit；额外两位只用于当拍的上下溢判断。
    localparam int EXP_CALC_WIDTH = 10;

    logic [255:0] a_scale_q;
    logic [255:0] b_scale_q;

    // 第 1 级：MX 点积与 C 对阶后的补码尾数。
    logic                                         s1_valid_q;
    logic signed [TILE_COLS * 29 - 1 : 0]         s1_large_sig_q;
    logic signed [TILE_COLS * 29 - 1 : 0]         s1_small_align_q;
    logic [TILE_COLS * 8 - 1 : 0]                 s1_large_exp_q;

    // 第 2 级：对阶后的补码和。
    logic                                         s2_valid_q;
    logic [TILE_COLS * 8 - 1 : 0]                 s2_exp_q;
    logic signed [TILE_COLS * 29 - 1 : 0]        s2_sum_q;

    // 第 3 级：规格化后的尾数和指数，供第 4 级处理边界编码。
    logic                                         s3_valid_q;
    logic signed [TILE_COLS * 25 - 1 : 0]         s3_sig_q;
    logic signed [TILE_COLS * EXP_CALC_WIDTH - 1 : 0] s3_exp_q;
    logic [TILE_COLS-1:0]                        s3_zero_q;
    logic [TILE_COLS-1:0]                        s3_sign_q;

    // 正数保持原值，负数先按位取反，再共用同一套前导零检测硬件。
    function automatic [4:0] leading_zero_count_24;
        input [23:0] value_i;
        integer bit_idx;
        reg found_one;
        begin
            leading_zero_count_24 = 5'd24;
            found_one = 1'b0;
            for (bit_idx = 23; bit_idx >= 0; bit_idx = bit_idx - 1) begin
                if (value_i[bit_idx] && !found_one) begin
                    leading_zero_count_24 = 5'd23 - bit_idx[4:0];
                    found_one = 1'b1;
                end
            end
        end
    endfunction

    function automatic [4:0] leading_zero_count_27;
        input [26:0] value_i;
        integer bit_idx;
        reg found_one;
        begin
            leading_zero_count_27 = 5'd27;
            found_one = 1'b0;
            for (bit_idx = 26; bit_idx >= 0; bit_idx = bit_idx - 1) begin
                if (value_i[bit_idx] && !found_one) begin
                    leading_zero_count_27 = 5'd26 - bit_idx[4:0];
                    found_one = 1'b1;
                end
            end
        end
    endfunction

    // 有符号右移并把被丢弃的非零位压入 bit0，供最终 RNE 使用。
    function automatic [28:0] shift_right_jam_signed_29;
        input [28:0] value_i;
        input [11:0] shift_i;
        integer bit_idx;
        reg [28:0] shifted_value;
        reg        sticky_value;
        begin
            shifted_value = '0;
            sticky_value  = 1'b0;
            if (shift_i >= 12'd29) begin
                shifted_value = {29{value_i[28]}};
                sticky_value  = |value_i[27:0];
            end else begin
                shifted_value = $signed(value_i) >>> shift_i;
                for (bit_idx = 0; bit_idx < 29; bit_idx = bit_idx + 1) begin
                    if (bit_idx < shift_i)
                        sticky_value = sticky_value | value_i[bit_idx];
                end
            end
            shifted_value[0] = shifted_value[0] | sticky_value;
            shift_right_jam_signed_29 = shifted_value;
        end
    endfunction

    // scale SRAM 返回优先于 A scale 消费。A scale 每个有效点积消费一个字节。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_scale_q <= '0;
        end else if (a_scale_data_valid_i) begin
            a_scale_q <= a_scale_data_i;
        end else if (valid_i) begin
            a_scale_q <= {8'b0, a_scale_q[255:8]};
        end
    end

    // B scale 在一个输出 block 内保持不变，按列索引读取。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_scale_q <= '0;
        end else if (b_scale_data_valid_i) begin
            b_scale_q <= b_scale_data_i;
        end
    end

    genvar col_idx;
    generate
        for (col_idx = 0; col_idx < TILE_COLS; col_idx = col_idx + 1) begin : g_stage1
            logic [PE_ACC_WIDTH-1:0] pe_value_w;
            logic                    pe_sign_w;
            logic                    pe_zero_w;
            logic signed [24:0]      pe_sig_ext_w;
            logic [23:0]             pe_norm_detect_w;
            logic [4:0]              pe_norm_lzc_w;
            logic [5:0]              pe_norm_shift_w;
            logic signed [24:0]      pe_norm_sig_w;
            logic signed [EXP_CALC_WIDTH-1:0] pe_exp_calc_w;
            logic [7:0]              pe_exp_w;
            logic                    pe_exp_underflow_w;
            logic                    pe_exp_overflow_w;
            logic signed [24:0]      pe_result_sig_w;
            logic                    pe_result_zero_w;
            logic [7:0]              a_scale_w;
            logic [7:0]              b_scale_w;

            logic [31:0]             c_value_w;
            logic                    c_zero_w;
            logic                    c_sign_w;
            logic [7:0]              c_exp_w;
            logic [22:0]             c_frac_w;
            logic signed [24:0]      c_sig_w;
            logic                    p_large_w;
            logic [7:0]              align_shift_w;
            logic [7:0]              large_exp_w;
            logic signed [24:0]      p_align_sig_w;
            logic [28:0]             p_ext_w;
            logic [28:0]             c_ext_w;
            logic [28:0]             large_sig_w;
            logic [28:0]             small_sig_w;
            logic [28:0]             small_align_w;

            assign pe_value_w = add_pe_i[col_idx*PE_ACC_WIDTH +: PE_ACC_WIDTH];
            assign pe_sign_w  = pe_value_w[PE_ACC_WIDTH-1];
            assign pe_zero_w  = (pe_value_w == '0);
            assign pe_sig_ext_w = {{(25-PE_ACC_WIDTH){pe_sign_w}}, pe_value_w};
            assign pe_norm_detect_w =
                pe_sig_ext_w[23:0] ^ {24{pe_sign_w}};
            assign pe_norm_lzc_w = leading_zero_count_24(pe_norm_detect_w);
            assign pe_norm_shift_w = pe_zero_w ? 6'd0 :
                                     {1'b0, pe_norm_lzc_w};
            assign pe_norm_sig_w = pe_zero_w ? 25'sd0 :
                                   (pe_sig_ext_w <<< pe_norm_shift_w);

            assign a_scale_w = a_scale_q[7:0];
            assign b_scale_w = b_scale_q[col_idx*8 +: 8];

            // 补码尾数左移 L 位后，指数同步减 L。常数 116 来自
            // MXINT8 scale 偏置、C 指数偏置和 23 位小数位的合并。
            assign pe_exp_calc_w = $signed({2'b00, a_scale_w}) +
                                   $signed({2'b00, b_scale_w}) -
                                   10'sd116 -
                                   $signed({4'd0, pe_norm_shift_w});
            assign pe_exp_underflow_w = !pe_zero_w && (pe_exp_calc_w <= 10'sd0);
            assign pe_exp_overflow_w = !pe_zero_w && (pe_exp_calc_w >= 10'sd255);
            assign pe_exp_w = (pe_zero_w || pe_exp_underflow_w) ? 8'd0 :
                              pe_exp_overflow_w ? 8'd254 :
                              pe_exp_calc_w[7:0];
            assign pe_result_sig_w = pe_exp_overflow_w ? (pe_sign_w ? 25'sh1000001 : 25'sh0ffffff) :
                                     pe_norm_sig_w;
            assign pe_result_zero_w = pe_zero_w || pe_exp_underflow_w;

            // 解码 C Reg 的定制补码尾数。零不恢复隐藏位。
            assign c_value_w = add_rd_i[col_idx*32 +: 32];
            assign c_zero_w  = (c_value_w == 32'b0);
            assign c_sign_w  = c_value_w[23];
            assign c_exp_w   = c_value_w[31:24];
            assign c_frac_w  = c_value_w[22:0];
            assign c_sig_w   = c_zero_w ? 25'sd0 :
                               $signed({c_sign_w, ~c_sign_w, c_frac_w});

            assign p_large_w = c_zero_w ? 1'b1 :
                               pe_result_zero_w ? 1'b0 :
                               (pe_exp_w >= c_exp_w);
            assign large_exp_w = p_large_w ? pe_exp_w : c_exp_w;
            assign align_shift_w = (pe_result_zero_w || c_zero_w) ? 8'd0 :
                                   p_large_w ? pe_exp_w - c_exp_w :
                                               c_exp_w - pe_exp_w;
            assign p_align_sig_w = pe_result_zero_w ? 25'sd0 :
                                   pe_result_sig_w;
            assign p_ext_w = {p_align_sig_w[24], p_align_sig_w, 3'b000};
            assign c_ext_w = {c_sig_w[24], c_sig_w, 3'b000};
            assign large_sig_w = p_large_w ? p_ext_w : c_ext_w;
            assign small_sig_w = p_large_w ? c_ext_w : p_ext_w;
            assign small_align_w =
                shift_right_jam_signed_29(small_sig_w, align_shift_w);

            // 第 1 拍锁存已经对阶的两个补码尾数和公共指数。
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    s1_large_sig_q[col_idx*29 +: 29] <= '0;
                    s1_small_align_q[col_idx*29 +: 29] <= '0;
                    s1_large_exp_q[col_idx*8 +: 8] <= '0;
                end else if (valid_i) begin
                    s1_large_sig_q[col_idx*29 +: 29] <= large_sig_w;
                    s1_small_align_q[col_idx*29 +: 29] <= small_align_w;
                    s1_large_exp_q[col_idx*8 +: 8] <= large_exp_w;
                end
            end
        end
    endgenerate

    generate
        for (col_idx = 0; col_idx < TILE_COLS; col_idx = col_idx + 1) begin : g_stage2
            logic [25:0] sum_upper_w;
            logic [25:0] sum_plus1_upper_w;
            logic [28:0] inter0_w;
            logic [28:0] inter1_w;
            logic [28:0] left_round_w;
            logic [28:0] selected_sum_w;
            logic        sum_zero_w;
            logic        sum_sign_w;
            logic        right_norm_w;
            logic        left_norm_w;
            logic        round_up_r1_w;
            logic        round_up_n0_w;
            logic        round_up_l1_w;
            logic        round_up_w;

            // 两个操作数的低三位中，大操作数恒为 000，因此低三位
            // 不会向 bit[3] 产生进位。FPPA 只计算 [28:3]，其
            // sum_plus1_o 等价于完整结果在 bit[3] 上加 1。
            FPPA #(
                .WIDTH ( 26 )
            ) u_sum_fppa (
                .x_i           ( s1_large_sig_q[col_idx*29 + 3 +: 26] ),
                .y_i           ( s1_small_align_q[col_idx*29 + 3 +: 26] ),
                .sum_o         ( sum_upper_w                         ),
                .sum_plus1_o   ( sum_plus1_upper_w                   ),
                .carry_o       (                                      ),
                .carry_plus1_o (                                      )
            );

            assign inter0_w = {sum_upper_w,
                               s1_small_align_q[col_idx*29 +: 3]};
            assign inter1_w = {sum_plus1_upper_w,
                               s1_small_align_q[col_idx*29 +: 3]};

            assign sum_zero_w = (inter0_w == 29'd0);
            assign sum_sign_w = inter0_w[28];

            // 规格化方向只根据未舍入结果判断，和 FPPA 两路结果的
            // 选择相互独立。舍入造成的进位会在第 3 拍重新检查。
            assign right_norm_w = !sum_zero_w &&
                                  (sum_sign_w ? !inter0_w[27] :
                                                inter0_w[27]);
            assign left_norm_w = !sum_zero_w && !right_norm_w &&
                                 (sum_sign_w ? inter0_w[26] :
                                               !inter0_w[26]);

            // R1：右规一位后，保留位为原 bit[4]。
            assign round_up_r1_w = inter0_w[3] &&
                                   (inter0_w[2] || inter0_w[1] ||
                                    inter0_w[0] || inter0_w[4]);
            // N0：不移位时，保留位为原 bit[3]。
            assign round_up_n0_w = inter0_w[2] &&
                                   (inter0_w[1] || inter0_w[0] ||
                                    inter0_w[3]);
            // L1：左规一位后，保留位为原 bit[2]。
            assign round_up_l1_w = inter0_w[1] &&
                                   (inter0_w[0] || inter0_w[2]);

            assign round_up_w = right_norm_w ? round_up_r1_w :
                                left_norm_w  ? round_up_l1_w :
                                               round_up_n0_w;

            // FPPA 直接给出 S+8。左规一位时实际需要 S+4，利用
            // S+8 的高位结果和 bit[2] 的局部翻转构造，不再增加完整
            // 的尾数加法器。
            assign left_round_w[28:3] = inter0_w[2] ?
                                        inter1_w[28:3] : inter0_w[28:3];
            assign left_round_w[2] = !inter0_w[2];
            assign left_round_w[1:0] = inter0_w[1:0];

            assign selected_sum_w = !round_up_w ? inter0_w :
                                    left_norm_w ? left_round_w : inter1_w;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    s2_exp_q[col_idx*8 +: 8] <= '0;
                    s2_sum_q[col_idx*29 +: 29] <= '0;
                end else if (s1_valid_q) begin
                    s2_exp_q[col_idx*8 +: 8] <=
                        s1_large_exp_q[col_idx*8 +: 8];
                    s2_sum_q[col_idx*29 +: 29] <= selected_sum_w;
                end
            end
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid_q <= 1'b0;
            s2_valid_q <= 1'b0;
            s3_valid_q <= 1'b0;
        end else begin
            s1_valid_q <= valid_i;
            s2_valid_q <= s1_valid_q;
            s3_valid_q <= s2_valid_q;
        end
    end

    genvar pack_idx;
    generate
        for (pack_idx = 0; pack_idx < TILE_COLS; pack_idx = pack_idx + 1) begin : g_stage3
            logic signed [28:0] sum_value_w;
            logic               sum_zero_w;
            logic               sum_sign_w;
            logic               right_norm_w;
            logic [26:0]        norm_detect_w;
            logic [4:0]         norm_lzc_w;
            logic [5:0]         left_shift_w;
            logic signed [28:0] norm_sum_w;
            logic signed [EXP_CALC_WIDTH-1:0] norm_exp_w;
            logic signed [24:0] normalized_sig_w;

            assign sum_value_w = $signed(s2_sum_q[pack_idx*29 +: 29]);
            assign sum_zero_w  = (sum_value_w == 29'sd0);
            assign sum_sign_w  = sum_value_w[28];

            // 正数 bit27=1 或负数 bit27=0 都表示尾数绝对值不小于 2，
            // 需要右规一位。其余情况直接在补码上做左规。
            assign right_norm_w = !sum_zero_w &&
                                  (sum_sign_w ? !sum_value_w[27] :
                                                sum_value_w[27]);

            // 正数寻找前导 0，负数先取反后寻找前导 0，从而用同一套
            // LZC 同时得到正数前导零数和负数前导符号 1 的数量。
            assign norm_detect_w = sum_value_w[26:0] ^ {27{sum_sign_w}};
            assign norm_lzc_w = leading_zero_count_27(norm_detect_w);
            assign left_shift_w = (sum_zero_w || right_norm_w) ? 6'd0 :
                                  {1'b0, norm_lzc_w};

            assign norm_sum_w = sum_zero_w ? 29'sd0 :
                                right_norm_w ?
                                $signed(shift_right_jam_signed_29(sum_value_w,
                                                                  12'd1)) :
                                ($signed(sum_value_w) <<< left_shift_w);
            assign norm_exp_w =
                $signed({2'b00, s2_exp_q[pack_idx*8 +: 8]}) +
                (right_norm_w ? 10'sd1 : 10'sd0) -
                $signed({4'd0, left_shift_w});

            // 第 2 拍已经由 FPPA 完成舍入选择，这里直接取规格化后
            // 的有效补码尾数，避免再串接一个舍入加法器。
            assign normalized_sig_w = $signed(norm_sum_w[27:3]);

            // 第 3 拍寄存规格化结果，切断可变移位到边界编码的组合路径。
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    s3_sig_q[pack_idx*25 +: 25] <= '0;
                    s3_exp_q[pack_idx*EXP_CALC_WIDTH +: EXP_CALC_WIDTH] <= '0;
                    s3_zero_q[pack_idx] <= 1'b0;
                    s3_sign_q[pack_idx] <= 1'b0;
                end else if (s2_valid_q) begin
                    s3_sig_q[pack_idx*25 +: 25] <= normalized_sig_w;
                    s3_exp_q[pack_idx*EXP_CALC_WIDTH +: EXP_CALC_WIDTH] <= norm_exp_w;
                    s3_zero_q[pack_idx] <= sum_zero_w;
                    s3_sign_q[pack_idx] <= sum_sign_w;
                end
            end
        end
    endgenerate

    genvar result_idx;
    generate
        for (result_idx = 0; result_idx < TILE_COLS; result_idx = result_idx + 1) begin : g_stage4
            logic [31:0] result_w;
            logic negative_one_w;
            logic signed [24:0] result_sig_w;
            logic signed [EXP_CALC_WIDTH-1:0] result_exp_w;
            logic result_zero_w;
            logic result_overflow_w;

            // -1.0 的补码尾数改写为 -2.0，指数减一以保持数值不变。
            assign negative_one_w = s3_sign_q[result_idx] &&
                                    (s3_sig_q[result_idx*25 +: 25] == 25'sh1800000);
            assign result_sig_w = negative_one_w ?
                                  25'sh1000000 : s3_sig_q[result_idx*25 +: 25];
            assign result_exp_w = $signed(s3_exp_q[result_idx*EXP_CALC_WIDTH +: EXP_CALC_WIDTH]) -
                                  (negative_one_w ? 10'sd1 : 10'sd0);
            // 下溢或精确抵消写零，上溢饱和到最大有限值。
            assign result_zero_w = s3_zero_q[result_idx] || (result_exp_w <= 10'sd0);
            assign result_overflow_w = (result_exp_w >= 10'sd255);
            assign result_w = result_zero_w ? 32'b0 :
                              result_overflow_w ?
                              (result_sig_w[24] ?
                               32'hfe800001 : 32'hfe7fffff) :
                              {result_exp_w[7:0], result_sig_w[24], result_sig_w[22:0]};

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    sum_o[result_idx*32 +: 32] <= '0;
                else if (s3_valid_q)
                    sum_o[result_idx*32 +: 32] <= result_w;
            end
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            valid_o <= 1'b0;
        else
            valid_o <= s3_valid_q;
    end

endmodule
