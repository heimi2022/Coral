`timescale 1ns/1ps

// Fixed-configuration single-port SRAM:
// - depth      : 1
// - row width  : 4096 Byte = 32768 bit
// - addr width : 1 bit
module sram_sp_1x4096B (
  output logic [32767:0] Q,
  input  logic           CLK,
  input  logic           CEN,
  input  logic           WEN,
  input  logic [0:0]     A,
  input  logic [32767:0] D
);

  sram_sp #(
    .DATA_WIDTH ( 32768 ),
    .DEPTH      ( 1     ),
    .ADDR_WIDTH ( 1     )
  ) u_sram_sp (
    .Q         ( Q               ),
    .CLK       ( CLK             ),
    .CEN       ( CEN             ),
    .WEN       ( WEN             ),
    .A         ( A               ),
    .D         ( D               ),
    .EMA       ( 3'b000          ),
    .EMAW      ( 2'b00           ),
    .EMAS      ( 1'b0            ),
    .RET1N     ( 1'b1            )
  );

endmodule
