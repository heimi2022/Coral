/*
标识并行前缀加法器（FPPA, dual-adder）

同一套 Kogge-Stone 风格的前缀 generate/propagate 网络，同时计算：
    sum_o       = x_i + y_i
    sum_plus1_o = x_i + y_i + 1

两路结果分别使用 Cin=0 和 Cin=1，但共享全部 group generate/propagate。
sum_plus1_o 不依赖 sum_o，不会在主加法器后串联第二个加法器。
*/
module FPPA #(
    parameter int WIDTH = 32
) (
    input  logic [WIDTH-1:0] x_i,
    input  logic [WIDTH-1:0] y_i,
    output logic [WIDTH-1:0] sum_o,
    output logic [WIDTH-1:0] sum_plus1_o,
    output logic             carry_o,
    output logic             carry_plus1_o
);

    localparam int PREFIX_STAGES = $clog2(WIDTH);

    // bit_propagate=1 表示该位会传递输入进位；bit_generate=1 表示该位自产生进位。
    logic [WIDTH-1:0] bit_propagate;
    logic [WIDTH-1:0] bit_generate;

    // prefix_*[stage][bit] 表示从 bit 到 bit0 的 group generate/propagate。
    logic [WIDTH-1:0] prefix_generate [0:PREFIX_STAGES];
    logic [WIDTH-1:0] prefix_propagate[0:PREFIX_STAGES];

    logic [WIDTH-1:0] carry_in_zero;
    logic [WIDTH-1:0] carry_in_one;

    assign bit_propagate = x_i ^ y_i;
    assign bit_generate  = x_i & y_i;

    assign prefix_generate[0]  = bit_generate;
    assign prefix_propagate[0] = bit_propagate;

    // 每一级把可见范围扩大一倍，深度为 ceil(log2(WIDTH))。
    genvar stage_idx;
    genvar bit_idx;
    generate
        for (stage_idx = 0; stage_idx < PREFIX_STAGES;
             stage_idx = stage_idx + 1) begin : g_prefix_stage
            for (bit_idx = 0; bit_idx < WIDTH; bit_idx = bit_idx + 1) begin : g_prefix_bit
                if (bit_idx >= (1 << stage_idx)) begin : g_combine
                    assign prefix_generate[stage_idx + 1][bit_idx] =
                        prefix_generate[stage_idx][bit_idx] |
                        (prefix_propagate[stage_idx][bit_idx] &
                         prefix_generate[stage_idx][bit_idx - (1 << stage_idx)]);
                    assign prefix_propagate[stage_idx + 1][bit_idx] =
                        prefix_propagate[stage_idx][bit_idx] &
                        prefix_propagate[stage_idx][bit_idx - (1 << stage_idx)];
                end else begin : g_pass
                    assign prefix_generate[stage_idx + 1][bit_idx] =
                        prefix_generate[stage_idx][bit_idx];
                    assign prefix_propagate[stage_idx + 1][bit_idx] =
                        prefix_propagate[stage_idx][bit_idx];
                end
            end
        end
    endgenerate

    // 两组 c[i] 分别对应最低位输入进位为 0 和 1。
    assign carry_in_zero[0] = 1'b0;
    assign carry_in_one[0]  = 1'b1;

    generate
        for (bit_idx = 1; bit_idx < WIDTH; bit_idx = bit_idx + 1) begin : g_carry
            assign carry_in_zero[bit_idx] = prefix_generate[PREFIX_STAGES][bit_idx - 1];
            assign carry_in_one[bit_idx] =
                prefix_generate[PREFIX_STAGES][bit_idx - 1] |
                prefix_propagate[PREFIX_STAGES][bit_idx - 1];
        end
    endgenerate

    assign sum_o       = bit_propagate ^ carry_in_zero;
    assign sum_plus1_o = bit_propagate ^ carry_in_one;

    assign carry_o = prefix_generate[PREFIX_STAGES][WIDTH - 1];
    assign carry_plus1_o = prefix_generate[PREFIX_STAGES][WIDTH - 1] |
                           prefix_propagate[PREFIX_STAGES][WIDTH - 1];

endmodule
