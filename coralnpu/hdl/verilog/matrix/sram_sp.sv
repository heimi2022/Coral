`timescale 1ns/1ps

// 单端口 SRAM 行为模型，端口与当前 memory compiler 宏保持一致：
// Q, CLK, CEN, WEN, A, D, EMA, EMAW, EMAS, RET1N。
//
// 主要功能端口：
// - Q        : 读数据输出。
// - CLK      : 时钟，存储器在时钟上升沿进行访问。
// - CEN      : 片选，低有效。为高时 SRAM 空闲，不进行访问。
// - WEN      : 整字写使能，低有效。
// - A        : 字地址输入。
// - D        : 写数据输入。
// - EMA      : 3-bit 额外裕量调节配置。
// - EMAW     : 写路径裕量调节配置。
// - EMAS     : 裕量调节选择信号。
// - RET1N    : 保持模式控制，通常为低有效低功耗保持信号。
//
// WEN 按低有效整字写语义建模。EMA/EMAW/EMAS/RET1N 仅为接口兼容保留，
// 行为模型不对其建模。
module sram_sp #(
  parameter integer DATA_WIDTH = 32,
  parameter integer DEPTH      = 1024,
  parameter integer ADDR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
  output logic [DATA_WIDTH-1:0] Q,
  input  logic                  CLK,
  input  logic                  CEN,
  input  logic                  WEN,
  input  logic [ADDR_WIDTH-1:0] A,
  input  logic [DATA_WIDTH-1:0] D,
  input  logic [2:0]            EMA,
  input  logic [1:0]            EMAW,
  input  logic                  EMAS,
  input  logic                  RET1N
);

  logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
  integer                addr_idx;

  always @(posedge CLK) begin
    if (CEN === 1'b0) begin
      if (^A === 1'bx) begin
        Q <= {DATA_WIDTH{1'bx}};
      end else if (A >= DEPTH) begin
        Q <= {DATA_WIDTH{1'bx}};
      end else begin
        addr_idx = A;
        if (WEN === 1'b0) begin
          mem[addr_idx] <= D;
          Q             <= D;
        end else begin
          Q <= mem[addr_idx];
        end
      end
    end else if (CEN !== 1'b1) begin
      Q <= {DATA_WIDTH{1'bx}};
    end
  end

endmodule
