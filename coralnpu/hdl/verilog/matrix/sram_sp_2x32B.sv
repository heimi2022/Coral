`timescale 1ns/1ps

// 固定规格单端口 SRAM：2 行 x 32 Byte。
// 地址 0/1 分别保存低/高 K block 的 32 个 scale。
module sram_sp_2x32B (
    output logic [255:0] Q,
    input  logic         CLK,
    input  logic         CEN,
    input  logic         WEN,
    input  logic         A,
    input  logic [255:0] D
);

    sram_sp #(
        .DATA_WIDTH ( 256 ),
        .DEPTH      ( 2   ),
        .ADDR_WIDTH ( 1   )
    ) u_sram_sp (
        .Q     ( Q        ),
        .CLK   ( CLK      ),
        .CEN   ( CEN      ),
        .WEN   ( WEN      ),
        .A     ( A        ),
        .D     ( D        ),
        .EMA   ( 3'b000   ),
        .EMAW  ( 2'b00    ),
        .EMAS  ( 1'b0     ),
        .RET1N ( 1'b1     )
    );

endmodule
