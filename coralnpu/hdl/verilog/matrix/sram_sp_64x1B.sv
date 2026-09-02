`timescale 1ns/1ps

// 固定规格单端口 SRAM：深度64，每行1 Byte（8 bit）。
// WEN 为低有效整字写使能。
module sram_sp_64x1B (
  output logic [7:0] Q,
  input  logic       CLK,
  input  logic       CEN,
  input  logic       WEN,
  input  logic [5:0] A,
  input  logic [7:0] D
);

  sram_sp #(
    .DATA_WIDTH ( 8  ),
    .DEPTH      ( 64 ),
    .ADDR_WIDTH ( 6  )
  ) u_sram_sp (
    .Q    ( Q       ),
    .CLK  ( CLK     ),
    .CEN  ( CEN     ),
    .WEN  ( WEN     ),
    .A    ( A       ),
    .D    ( D       ),
    .EMA  ( 3'b000  ),
    .EMAW ( 2'b00   ),
    .EMAS ( 1'b0    ),
    .RET1N( 1'b1    )
  );

endmodule
