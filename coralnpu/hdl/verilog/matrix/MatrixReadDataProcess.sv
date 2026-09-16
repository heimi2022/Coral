/* 矩阵寄存器读出数据处理：定制 C 格式转 IEEE FP32，并提供一级弹性缓存。 */
module MatrixReadDataProcess #(
    parameter int DATA_W = 512
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                in_valid_i,
    output logic                in_ready_o,
    input  logic [DATA_W-1:0]   in_data_i,
    input  logic                convert_c_i,    // 是否将定制 C 格式转换为 IEEE FP32
    output logic                out_valid_o,
    input  logic                out_ready_i,
    output logic [DATA_W-1:0]   out_data_o
);
    logic [DATA_W-1:0] data_q;
    logic              valid_q;
    logic              convert_c_q;

    // 与 accumulaters 一致：指数偏置 127，尾数为 {sign, ~sign, fraction}。
    // 有效输入为全零或指数 1..254 的有限数；不支持定制次正规数/Inf/NaN。
    function automatic [31:0] custom_to_fp32(input logic [31:0] value);
        logic [22:0] magnitude_fraction;
        logic [7:0] exponent;
        begin
            exponent = value[31:24];
            magnitude_fraction = (~value[22:0]) + 23'd1;
            if (exponent == 0)
                custom_to_fp32 = 32'b0;
            else if (exponent == 8'hff)
                // 保留编码不应由累加器产生；确定性输出 quiet NaN。
                custom_to_fp32 = 32'h7fc00000;
            else if (!value[23])
                custom_to_fp32 = {1'b0, exponent, value[22:0]};
            else if (value[22:0] == 0)
                // 10.000... 表示 -2.0；改为 -1.0 并提升指数，溢出成为 -Inf。
                custom_to_fp32 = {1'b1, (exponent + 8'd1), 23'b0};
            else
                custom_to_fp32 = {1'b1, exponent, magnitude_fraction};
        end
    endfunction

    genvar lane;
    generate
    for (lane = 0; lane < DATA_W / 32; lane = lane + 1) begin : g_convert
        // 转换放在寄存器之后，背压时数据和转换模式一同保持。
        assign out_data_o[lane*32 +: 32] = convert_c_q ?
            custom_to_fp32(data_q[lane*32 +: 32]) : data_q[lane*32 +: 32];
    end
    endgenerate

    assign out_valid_o = valid_q;
    assign in_ready_o  = !valid_q || out_ready_i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_q  <= '0;
            valid_q <= 1'b0;
            convert_c_q <= 1'b0;
        end else if (in_ready_o) begin
            valid_q <= in_valid_i;
            if (in_valid_i) begin
                data_q <= in_data_i;
                convert_c_q <= convert_c_i;
            end
        end
    end
endmodule
