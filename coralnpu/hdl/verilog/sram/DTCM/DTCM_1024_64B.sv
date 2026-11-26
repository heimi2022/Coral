`timescale 1ns/1ps

// 64 KiB single-port SRAM: 1024 rows x 64 bytes.
// Four 1024 x 16-byte macros share one row address and access direction.
module DTCM_1024_64B #(
    parameter logic [2:0] EMA_VALUE  = 3'b011,
    parameter logic [1:0] EMAW_VALUE = 2'b01,
    parameter logic       EMAS_VALUE = 1'b0
) (
`ifdef POWER_PINS
    inout wire          VDDCE,
    inout wire          VDDPE,
    inout wire          VSSE,
`endif
    input  wire         clock,
    input  wire         enable,
    input  wire         write,
    // Row index, corresponding to byte offset [15:6] within this unit.
    input  wire [9:0]   addr,
    input  wire [511:0] wdata,
    // Active-high byte enables: wmask[i] controls wdata[8*i +: 8].
    input  wire [63:0]  wmask,
    // Synchronous macro read output; only consume after an enabled read.
    output wire [511:0] rdata
);

    wire [511:0] bit_wen_n;

    generate
        for (genvar byte_idx = 0; byte_idx < 64; byte_idx++) begin : gen_byte_mask
            // The macro expects active-low write enables for individual bits.
            assign bit_wen_n[byte_idx * 8 +: 8] = {8{~wmask[byte_idx]}};
        end

        for (genvar bank_idx = 0; bank_idx < 4; bank_idx++) begin : gen_bank
            // Bank 0 holds bytes 0..15, bank 1 holds bytes 16..31, etc.
            DTCM_1024_16B u_sram (
`ifdef POWER_PINS
                .VDDCE (VDDCE),
                .VDDPE (VDDPE),
                .VSSE  (VSSE),
`endif
                .Q     (rdata[bank_idx * 128 +: 128]),
                .CLK   (clock),
                .CEN   (~enable),
                .WEN   (bit_wen_n[bank_idx * 128 +: 128]),
                .A     (addr),
                .D     (wdata[bank_idx * 128 +: 128]),
                .EMA   (EMA_VALUE),
                .EMAW  (EMAW_VALUE),
                .EMAS  (EMAS_VALUE),
                .GWEN  (~write),
                .RET1N (1'b1)
            );
        end
    endgenerate

endmodule
