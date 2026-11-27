`timescale 1ns/1ps

`ifdef VERILATOR
// Two-state functional model for Verilator. The compiler model's X/Z clock
// checks are incompatible with Verilator 5.032; synthesis uses the real macro.
module DTCM_1024_16B_sim (
`ifdef POWER_PINS
    inout wire VDDCE,
    inout wire VDDPE,
    inout wire VSSE,
`endif
    output logic [127:0] Q,
    input wire CLK,
    input wire CEN,
    input wire [127:0] WEN,
    input wire [9:0] A,
    input wire [127:0] D,
    input wire [2:0] EMA,
    input wire [1:0] EMAW,
    input wire EMAS,
    input wire GWEN,
    input wire RET1N
);
    logic [127:0] memory [0:1023];

    // CEN, GWEN and each WEN bit are active low. Writes leave Q unchanged;
    // reads update Q after the rising edge, with no extra pipeline stage.
    always_ff @(posedge CLK) begin
        if (RET1N && !CEN) begin
            if (!GWEN) begin
                memory[A] <= (memory[A] & WEN) | (D & ~WEN);
            end else begin
                Q <= memory[A];
            end
        end
    end
endmodule
`endif
