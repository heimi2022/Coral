`timescale 1ns/1ps

// 固定规格单端口 SRAM：
// - 深度      : 32
// - 每行字宽  : 32 Byte = 256 bit
// - 地址宽度  : 5 bit
//
// 对外只保留常用功能端口：
// - Q / CLK / CEN / WEN / A / D
//
// EMA/EMAW/EMAS/RET1N 在模块内部绑成默认值，不再向外暴露。
module sram_sp_32x32B (
  output logic [255:0] Q,
  input  logic         CLK,
  input  logic         CEN,
  input  logic         WEN,
  input  logic [4:0]   A,
  input  logic [255:0] D
);

  sram_sp #(
    .DATA_WIDTH ( 256 ),
    .DEPTH      ( 32  ),
    .ADDR_WIDTH ( 5   )
  ) u_sram_sp (
    .Q         ( Q         ),
    .CLK       ( CLK       ),
    .CEN       ( CEN       ),
    .WEN       ( WEN       ),
    .A         ( A         ),
    .D         ( D         ),
    .EMA       ( 3'b000      ),
    .EMAW      ( 2'b00       ),
    .EMAS      ( 1'b0        ),
    .RET1N     ( 1'b1        )
  );

endmodule
