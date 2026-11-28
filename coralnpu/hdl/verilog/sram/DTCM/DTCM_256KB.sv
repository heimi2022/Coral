`timescale 1ns/1ps

// 256 KiB DTCM: four independently arbitrated 64 KiB single-port units.
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
    input  wire         reset,

    // Port 0 selects one or more 16-byte banks. Zero means no request.
    input  wire [3:0]   bank_enable0,
    input  wire         write0,
    input  wire [11:0]  addr0,
    input  wire [511:0] wdata0,
    input  wire [63:0]  wmask0,
    output wire         ready0,
    output logic        rvalid0,
    output wire [511:0] rdata0,

    // Port 1 always accesses all four 16-byte banks. valid means one 64-byte request.
    input  wire         valid1,
    input  wire         write1,
    input  wire [11:0]  addr1,
    input  wire [511:0] wdata1,
    input  wire [63:0]  wmask1,
    output wire         ready1,
    output logic        rvalid1,
    output wire [511:0] rdata1
);

    wire [3:0] request0_unit;
    wire [3:0] request1_unit;
    wire [3:0] grant0_unit;
    wire [3:0] grant1_unit;
    wire [511:0] unit_rdata [0:3];
    logic prefer1;
    logic [1:0] read_unit0_q;
    logic [1:0] read_unit1_q;

    logic [3:0] unit_bank_enable [0:3];
    logic       unit_write [0:3];
    logic [9:0] unit_addr [0:3];
    logic [511:0] unit_wdata [0:3];
    logic [63:0] unit_wmask [0:3];

    generate
        for (genvar unit_idx = 0; unit_idx < 4; unit_idx++) begin : gen_unit
            localparam logic [1:0] UNIT_INDEX = unit_idx;

            assign request0_unit[unit_idx] = (|bank_enable0) &&
                (addr0[11:10] == UNIT_INDEX);
            assign request1_unit[unit_idx] = valid1 &&
                (addr1[11:10] == UNIT_INDEX);

            // Each unit checks its own requests; contended units share the
            // global round-robin preference, while different units run in parallel.
            assign grant0_unit[unit_idx] = request0_unit[unit_idx] &&
                (!request1_unit[unit_idx] || !prefer1);
            assign grant1_unit[unit_idx] = request1_unit[unit_idx] &&
                (!request0_unit[unit_idx] || prefer1);

            assign unit_bank_enable[unit_idx] =
                ({4{grant0_unit[unit_idx]}} & bank_enable0) | {4{grant1_unit[unit_idx]}};
            assign unit_write[unit_idx] = grant0_unit[unit_idx] ? write0 : write1;
            assign unit_addr[unit_idx] = grant0_unit[unit_idx] ? addr0[9:0] : addr1[9:0];
            assign unit_wdata[unit_idx] = grant0_unit[unit_idx] ? wdata0 : wdata1;
            assign unit_wmask[unit_idx] = grant0_unit[unit_idx] ? wmask0 : wmask1;

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
                .clock       (clock),
                .write       (unit_write[unit_idx]),
                .bank_enable (unit_bank_enable[unit_idx]),
                .addr        (unit_addr[unit_idx]),
                .wdata       (unit_wdata[unit_idx]),
                .wmask       (unit_wmask[unit_idx]),
                .rdata       (unit_rdata[unit_idx])
            );
        end
    endgenerate

    always_ff @(posedge clock) begin
        if (reset) begin
            prefer1 <= 1'b0;
        end else if (|(request0_unit & request1_unit)) begin
            prefer1 <= !prefer1;
        end
    end

    assign ready0 = |grant0_unit;
    assign ready1 = |grant1_unit;

    always_ff @(posedge clock) begin
        if (reset) begin
            rvalid0 <= 1'b0;
            rvalid1 <= 1'b0;
            read_unit0_q <= 2'b00;
            read_unit1_q <= 2'b00;
        end else begin
            rvalid0 <= ready0 && !write0;
            rvalid1 <= ready1 && !write1;
            if (ready0 && !write0) begin
                read_unit0_q <= addr0[11:10];
            end
            if (ready1 && !write1) begin
                read_unit1_q <= addr1[11:10];
            end
        end
    end

    assign rdata0 = unit_rdata[read_unit0_q];
    assign rdata1 = unit_rdata[read_unit1_q];

endmodule
