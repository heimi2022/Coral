`timescale 1ns/1ps

// 单端口 SRAM 行为模型，接口风格参考新思一类 SRAM compiler 生成的宏模型。
//
// 主要功能端口：
// - Q        : 读数据输出。
// - CLK      : 时钟，存储器在时钟上升沿进行访问。
// - CEN      : 片选，低有效。为高时 SRAM 空闲，不进行访问。
// - WEN      : 写使能，低有效。一般表示整字写使能。
// - A        : 字地址输入。
// - D        : 写数据输入。
// - BWEN     : 按位写使能，低有效。某一位为 0 表示该 bit 写入，
//              为 1 表示该 bit 保持原值不变。
// - GWEN     : 全局写使能，低有效。通常与 BWEN 配合使用，实现掩码写。
//
// SRAM 编译器常见兼容/控制端口：
// - EMA      : 额外裕量调节使能，通常用于速度/时序裕量配置。
// - EMAW     : 写路径裕量调节配置。
// - EMAS     : 裕量调节选择信号。
// - TEN      : 测试使能。
// - BEN      : BIST/测试模式相关使能。
// - RET1N    : 保持模式控制，通常为低有效低功耗保持信号。
// - STOV     : 扫描/测试覆盖控制。
// - COLLDISN : 冲突检测关闭控制，部分宏中为低有效。
// - DFTRAMBYP: DFT RAM bypass 控制。
// - RTSEL    : 读时序裕量/修复相关选择。
// - WTSEL    : 写时序裕量/修复相关选择。
//
// 在当前行为模型中，只有 CLK/CEN/WEN/A/D/Q/BWEN/GWEN 会真正影响
// 存储器读写行为，其余端口仅为了和 SRAM 宏接口保持一致，未做功能建模。
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
  input  logic [DATA_WIDTH-1:0] BWEN,
  input  logic                  GWEN,
  input  logic                  EMA,
  input  logic [1:0]            EMAW,
  input  logic                  EMAS,
  input  logic                  TEN,
  input  logic                  BEN,
  input  logic                  RET1N,
  input  logic                  STOV,
  input  logic                  COLLDISN,
  input  logic                  DFTRAMBYP,
  input  logic [1:0]            RTSEL,
  input  logic [1:0]            WTSEL
);

  logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
  logic [DATA_WIDTH-1:0] write_mask;
  logic [DATA_WIDTH-1:0] next_word;
  integer                addr_idx;
  integer                bit_idx;

  function automatic integer pin_known(input logic pin);
    begin
      pin_known = (pin === 1'b0) || (pin === 1'b1);
    end
  endfunction

  function automatic integer bus_known(input logic [DATA_WIDTH-1:0] bus);
    begin
      bus_known = (^bus !== 1'bx);
    end
  endfunction

  // Common compiler/DFT pins are kept only for interface compatibility.
  always @* begin
    write_mask = {DATA_WIDTH{1'b0}};
    if (bus_known(BWEN)) begin
      if (!pin_known(GWEN) || (GWEN == 1'b0)) begin
        write_mask = ~BWEN;
      end
    end else if (pin_known(WEN) && (WEN == 1'b0)) begin
      write_mask = {DATA_WIDTH{1'b1}};
    end
  end

  always @(posedge CLK) begin
    if (CEN === 1'b0) begin
      if (^A === 1'bx) begin
        Q <= {DATA_WIDTH{1'bx}};
      end else if (A >= DEPTH) begin
        Q <= {DATA_WIDTH{1'bx}};
`ifndef SYNTHESIS
        $warning("%m: address 0x%0h out of range, DEPTH=%0d", A, DEPTH);
`endif
      end else begin
        addr_idx  = A;
        next_word = mem[addr_idx];

        for (bit_idx = 0; bit_idx < DATA_WIDTH; bit_idx = bit_idx + 1) begin
          if (write_mask[bit_idx]) begin
            next_word[bit_idx] = D[bit_idx];
          end
        end

        if (|write_mask) begin
          mem[addr_idx] <= next_word;
          Q             <= next_word;
        end else begin
          Q <= mem[addr_idx];
        end
      end
    end else if (CEN !== 1'b1) begin
      Q <= {DATA_WIDTH{1'bx}};
    end
  end

endmodule
