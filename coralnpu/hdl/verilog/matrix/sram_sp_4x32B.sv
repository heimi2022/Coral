`timescale 1ns/1ps

// Fixed-configuration single-port SRAM:
// - depth      : 4
// - row width  : 32 Byte = 256 bit
// - addr width : 2 bit
module sram_sp_4x32B (
  output logic [255:0] Q,
  input  logic         CLK,
  input  logic         CEN,
  input  logic         WEN,
  input  logic [1:0]   A,
  input  logic [255:0] D
);

  sram_sp #(
    .DATA_WIDTH ( 256 ),
    .DEPTH      ( 4   ),
    .ADDR_WIDTH ( 2   )
  ) u_sram_sp (
    .Q         ( Q            ),
    .CLK       ( CLK          ),
    .CEN       ( CEN          ),
    .WEN       ( WEN          ),
    .A         ( A            ),
    .D         ( D            ),
    .BWEN      ( {256{1'bx}}  ),
    .GWEN      ( 1'b1         ),
    .EMA       ( 1'b0         ),
    .EMAW      ( 2'b00        ),
    .EMAS      ( 1'b0         ),
    .TEN       ( 1'b0         ),
    .BEN       ( 1'b0         ),
    .RET1N     ( 1'b1         ),
    .STOV      ( 1'b0         ),
    .COLLDISN  ( 1'b1         ),
    .DFTRAMBYP ( 1'b0         ),
    .RTSEL     ( 2'b00        ),
    .WTSEL     ( 2'b00        )
  );

endmodule
