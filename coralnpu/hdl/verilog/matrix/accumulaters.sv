/*
32 路累加器阵列

作用：
1. 对脉动阵列当前输出和历史累加值做逐列相加。
2. 每一列使用一个 48bit 的 DW01_add。
3. 当前默认是 32 路，可通过参数改列数和位宽。

说明：
1. 这里按二进制补码做加法，因此有符号数和无符号数在位级加法上是一样的。
2. 输出 `sum_o` 是截断后的 ACC_WIDTH 位结果。
3. 每一路的进位输出保留在 `carry_o`，如果后面不需要可以不连接。
*/

module accumulaters #(
    parameter int TILE_COLS = 32,
    parameter int ACC_WIDTH = 48
) (
    input  logic [TILE_COLS * ACC_WIDTH - 1 : 0] add_pe_i,
    input  logic [TILE_COLS * ACC_WIDTH - 1 : 0] add_rd_i,
    output logic [TILE_COLS * ACC_WIDTH - 1 : 0] sum_o,
    output logic [TILE_COLS - 1 : 0]             carry_o
);

    genvar col_idx;
    generate
        for (col_idx = 0; col_idx < TILE_COLS; col_idx = col_idx + 1) begin : gen_accumulater
            DW01_add #(
                .width ( ACC_WIDTH )
            ) u_dw01_add (
                .A   ( add_pe_i[col_idx*ACC_WIDTH +: ACC_WIDTH] ),
                .B   ( add_rd_i[col_idx*ACC_WIDTH +: ACC_WIDTH]   ),
                .CI  ( 1'b0                                              ),
                .SUM ( sum_o[col_idx*ACC_WIDTH +: ACC_WIDTH]            ),
                .CO  ( carry_o[col_idx]                                  )
            );
        end
    endgenerate

endmodule
