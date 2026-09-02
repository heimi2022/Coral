`timescale 1ns/1ps

// AB 矩阵寄存器对应的 MXINT8 scale 寄存器文件。
//
// 每个 AB scale reg 保存64行、每行两个8-bit E8M0 scale，共128B：
//   bank0：64行 x 1B，K block 0
//   bank1：64行 x 1B，K block 1
//
// DMA 写一行16bit scale 时，同时写两个 bank，不需要 SRAM 的按位写或读改写。
module ABScaleReg (
    input  logic        clk,
    input  logic        rst_n,

    // DMA 每次写一个逻辑行：低8bit为 K block 0，高8bit为 K block 1。
    input  logic        dma_wr_en_i,
    input  logic [1:0]  dma_wr_reg_i,
    input  logic [5:0]  dma_wr_row_i,
    input  logic [15:0] dma_wr_data_i,

    // rd0、rd1 各读取一个 scale，读结果延迟一拍。
    input  logic        rd0_en_i,
    input  logic [1:0]  rd0_reg_i,
    input  logic [5:0]  rd0_row_i,
    input  logic        rd0_kblock_i,
    output logic        rd0_valid_o,
    output logic [7:0]  rd0_scale_o,

    input  logic        rd1_en_i,
    input  logic [1:0]  rd1_reg_i,
    input  logic [5:0]  rd1_row_i,
    input  logic        rd1_kblock_i,
    output logic        rd1_valid_o,
    output logic [7:0]  rd1_scale_o
);

    localparam int BANK_COUNT   = 2;

    logic [7:0] bank_q    [0 : 3][0:BANK_COUNT-1];
    logic       bank_cen  [0 : 3][0:BANK_COUNT-1];
    logic       bank_wen  [0 : 3][0:BANK_COUNT-1];
    logic [5:0] bank_addr [0 : 3][0:BANK_COUNT-1];
    logic [7:0] bank_d    [0 : 3][0:BANK_COUNT-1];

    logic [1:0] dma_bank_mask_w;
    logic [1:0] rd0_bank_mask_w;
    logic [1:0] rd1_bank_mask_w;
    logic       rd0_dma_conflict_w;
    logic       rd1_dma_conflict_w;
    logic       rd01_conflict_w;
    logic       rd0_accept_w;
    logic       rd1_accept_w;

    logic [1:0] rd0_reg_q;
    logic       rd0_bank_q;
    logic [1:0] rd1_reg_q;
    logic       rd1_bank_q;

    integer reg_idx;
    integer bank_idx;

    // DMA 每次写入当前行的两个 scale，因此两个 bank 同时被占用。
    assign dma_bank_mask_w = 2'b11;
    assign rd0_bank_mask_w = 2'b01 << rd0_kblock_i;
    assign rd1_bank_mask_w = 2'b01 << rd1_kblock_i;

    // 每个 bank 是单端口。不同 AB scale reg 的 bank 可以并行工作；同一个
    // bank 的 DMA 写、rd0、rd1 不能在同一拍同时发生。
    assign rd0_dma_conflict_w = dma_wr_en_i &&
                                (dma_wr_reg_i == rd0_reg_i) &&
                                (|(dma_bank_mask_w & rd0_bank_mask_w));
    assign rd1_dma_conflict_w = dma_wr_en_i &&
                                (dma_wr_reg_i == rd1_reg_i) &&
                                (|(dma_bank_mask_w & rd1_bank_mask_w));
    assign rd01_conflict_w = rd0_en_i && rd1_en_i &&
                             (rd0_reg_i == rd1_reg_i) &&
                             (|(rd0_bank_mask_w & rd1_bank_mask_w));
    assign rd0_accept_w = rd0_en_i && !rd0_dma_conflict_w;
    assign rd1_accept_w = rd1_en_i && !rd1_dma_conflict_w && !rd01_conflict_w;

    always @* begin
        for (reg_idx = 0; reg_idx < 4; reg_idx = reg_idx + 1) begin
            for (bank_idx = 0; bank_idx < BANK_COUNT; bank_idx = bank_idx + 1) begin
                bank_cen[reg_idx][bank_idx]  = 1'b1;
                bank_wen[reg_idx][bank_idx]  = 1'b1;
                bank_addr[reg_idx][bank_idx] = '0;
                bank_d[reg_idx][bank_idx]    = '0;
            end
        end

        if (dma_wr_en_i) begin
            bank_cen[dma_wr_reg_i][0]  = 1'b0;
            bank_wen[dma_wr_reg_i][0]  = 1'b0;
            bank_addr[dma_wr_reg_i][0] = dma_wr_row_i;
            bank_d[dma_wr_reg_i][0]    = dma_wr_data_i[7:0];

            bank_cen[dma_wr_reg_i][1]  = 1'b0;
            bank_wen[dma_wr_reg_i][1]  = 1'b0;
            bank_addr[dma_wr_reg_i][1] = dma_wr_row_i;
            bank_d[dma_wr_reg_i][1]    = dma_wr_data_i[15:8];
        end

        if (rd0_accept_w) begin
            bank_cen[rd0_reg_i][rd0_kblock_i]  = 1'b0;
            bank_wen[rd0_reg_i][rd0_kblock_i]  = 1'b1;
            bank_addr[rd0_reg_i][rd0_kblock_i] = rd0_row_i;
        end

        if (rd1_accept_w) begin
            bank_cen[rd1_reg_i][rd1_kblock_i]  = 1'b0;
            bank_wen[rd1_reg_i][rd1_kblock_i]  = 1'b1;
            bank_addr[rd1_reg_i][rd1_kblock_i] = rd1_row_i;
        end
    end

    genvar gen_reg_idx;
    genvar gen_bank_idx;
    generate
        for (gen_reg_idx = 0; gen_reg_idx < 4;
             gen_reg_idx = gen_reg_idx + 1) begin : g_ab_scale_reg
            for (gen_bank_idx = 0; gen_bank_idx < BANK_COUNT;
                 gen_bank_idx = gen_bank_idx + 1) begin : g_scale_bank
                sram_sp_64x1B u_sram (
                    .Q    ( bank_q[gen_reg_idx][gen_bank_idx]    ),
                    .CLK  ( clk                                   ),
                    .CEN  ( bank_cen[gen_reg_idx][gen_bank_idx]  ),
                    .WEN  ( bank_wen[gen_reg_idx][gen_bank_idx]  ),
                    .A    ( bank_addr[gen_reg_idx][gen_bank_idx] ),
                    .D    ( bank_d[gen_reg_idx][gen_bank_idx]    )
                );
            end
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd0_valid_o <= 1'b0;
            rd0_reg_q   <= '0;
            rd0_bank_q  <= 1'b0;
            rd1_valid_o <= 1'b0;
            rd1_reg_q   <= '0;
            rd1_bank_q  <= 1'b0;
        end else begin
            rd0_valid_o <= rd0_accept_w;
            rd1_valid_o <= rd1_accept_w;
            if (rd0_accept_w) begin
                rd0_reg_q  <= rd0_reg_i;
                rd0_bank_q <= rd0_kblock_i;
            end
            if (rd1_accept_w) begin
                rd1_reg_q  <= rd1_reg_i;
                rd1_bank_q <= rd1_kblock_i;
            end
        end
    end

    always @* begin
        rd0_scale_o = '0;
        if (rd0_valid_o) begin
            rd0_scale_o = bank_q[rd0_reg_q][rd0_bank_q];
        end

        rd1_scale_o = '0;
        if (rd1_valid_o) begin
            rd1_scale_o = bank_q[rd1_reg_q][rd1_bank_q];
        end
    end

endmodule
