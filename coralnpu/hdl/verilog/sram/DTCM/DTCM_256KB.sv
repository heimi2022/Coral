`timescale 1ns/1ps

// 256 KiB single-port DTCM: 4096 rows x 64 bytes.
// Four 64 KiB units extend the depth; only one unit is enabled per access.
module DTCM_256KB #(
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
    // Row index, corresponding to byte offset [17:6] within the DTCM.
    input  wire [11:0]  addr,
    input  wire [511:0] wdata,
    // Active-high byte enables: wmask[i] controls wdata[8*i +: 8].
    input  wire [63:0]  wmask,
    // Valid after an enabled synchronous read; no extra data pipeline stage.
    output wire [511:0] rdata
);

    wire [1:0] unit_select = addr[11:10];
    wire [511:0] unit_rdata [0:3];
    logic [1:0] read_unit_q;

    // Match the selected unit to the macro's synchronous read response.
    // No reset is needed: the first enabled read establishes the selection.
    always_ff @(posedge clock) begin
        if (enable && !write) begin
            read_unit_q <= unit_select;
        end
    end

    assign rdata = unit_rdata[read_unit_q];

    generate
        for (genvar unit_idx = 0; unit_idx < 4; unit_idx++) begin : gen_unit
            localparam logic [1:0] UNIT_INDEX = unit_idx;

            DTCM_1024_64B #(
                .EMA_VALUE  (EMA_VALUE),
                .EMAW_VALUE (EMAW_VALUE),
                .EMAS_VALUE (EMAS_VALUE)
            ) u_sram (
`ifdef POWER_PINS
                .VDDCE (VDDCE),
                .VDDPE (VDDPE),
                .VSSE  (VSSE),
`endif
                .clock  (clock),
                .enable (enable && (unit_select == UNIT_INDEX)),
                .write  (write),
                .addr   (addr[9:0]),
                .wdata  (wdata),
                .wmask  (wmask),
                .rdata  (unit_rdata[unit_idx])
            );
        end
    endgenerate

endmodule
