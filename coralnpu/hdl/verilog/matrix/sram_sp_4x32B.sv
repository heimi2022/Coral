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
    .EMA       ( 3'b000       ),
    .EMAW      ( 2'b00        ),
    .EMAS      ( 1'b0         ),
    .RET1N     ( 1'b1         )
  );

endmodule
