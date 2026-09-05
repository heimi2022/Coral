`timescale 1ns/1ps

// AB 矩阵寄存器对应的 MXINT8 scale 寄存器文件。
//
// 共 4 个 scale reg，每个 reg 由两个 2 x 32B 的单端口 SRAM bank 组成：
//   bank0：保存 M/N 维度索引 0~31 的 scale；
//   bank1：保存 M/N 维度索引 32~63 的 scale。
//
// 每个 bank 的地址表示 K block：
//   SRAM 地址 0：低 K block 的 scale；
//   SRAM 地址 1：高 K block 的 scale。
//
// DMA 每次写入一个 K block 上最多 64 个连续 scale：
//   dma_wr_data_i[255:0]   写入 bank0；
//   dma_wr_data_i[511:256] 写入 bank1。
// 不足 64 个 scale 时，DMA 输出侧需要将高位无效字节补零。
module ABScaleReg (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         dma_wr_en_i,
    input  logic [1:0]   dma_wr_reg_i,
    input  logic         dma_wr_kblock_i,
    input  logic [511:0] dma_wr_data_i,

    // row_i 选择 bank0/bank1；每次读出该 bank 的完整 32B 行，
    // 即 32 个连续的 8-bit scale。
    // kblock_i 选择低/高 K block 对应的 SRAM 行。
    input  logic         rd0_en_i,
    input  logic [1:0]   rd0_reg_i,
    input  logic         rd0_row_i,         //选择哪个bank
    input  logic         rd0_kblock_i,      // 选择哪一行
    output logic         rd0_valid_o,
    output logic [255:0] rd0_scale_o,

    input  logic         rd1_en_i,
    input  logic [1:0]   rd1_reg_i,
    input  logic         rd1_row_i,
    input  logic         rd1_kblock_i,
    output logic         rd1_valid_o,
    output logic [255:0] rd1_scale_o
);

    localparam int BANK_COUNT = 2;

    logic [255:0] bank_q    [0:3][0:BANK_COUNT-1];
    logic         bank_cen  [0:3][0:BANK_COUNT-1];
    logic         bank_wen  [0:3][0:BANK_COUNT-1];
    logic         bank_addr [0:3][0:BANK_COUNT-1];
    logic [255:0] bank_d    [0:3][0:BANK_COUNT-1];

    logic rd0_dma_conflict_w;
    logic rd1_dma_conflict_w;
    logic rd01_conflict_w;
    logic rd0_accept_w;
    logic rd1_accept_w;

    logic [1:0] rd0_reg_q;
    logic       rd0_bank_q;
    logic [1:0] rd1_reg_q;
    logic       rd1_bank_q;

    integer reg_idx;
    integer bank_idx;

    // DMA 同时占用目标 reg 的两个 bank。两个读口访问同一个 reg、同一个
    // bank 时，rd0 优先；访问不同 reg 或不同 bank 时可以并行读取。
    assign rd0_dma_conflict_w = dma_wr_en_i && (dma_wr_reg_i == rd0_reg_i);
    assign rd1_dma_conflict_w = dma_wr_en_i && (dma_wr_reg_i == rd1_reg_i);
    assign rd01_conflict_w = rd0_en_i && rd1_en_i &&
                             (rd0_reg_i == rd1_reg_i) &&
                             (rd0_row_i == rd1_row_i);

    assign rd0_accept_w = rd0_en_i && !rd0_dma_conflict_w;
    assign rd1_accept_w = rd1_en_i && !rd1_dma_conflict_w && !rd01_conflict_w;

    always @* begin
        for (reg_idx = 0; reg_idx < 4; reg_idx = reg_idx + 1) begin
            for (bank_idx = 0; bank_idx < BANK_COUNT; bank_idx = bank_idx + 1) begin
                bank_cen[reg_idx][bank_idx]  = 1'b1;
                bank_wen[reg_idx][bank_idx]  = 1'b1;
                bank_addr[reg_idx][bank_idx] = 1'b0;
                bank_d[reg_idx][bank_idx]    = '0;
            end
        end

        // 一个 DMA 写周期同时写入低、高各 32 个 M/N scale。
        if (dma_wr_en_i) begin
            bank_cen[dma_wr_reg_i][0]  = 1'b0;
            bank_wen[dma_wr_reg_i][0]  = 1'b0;
            bank_addr[dma_wr_reg_i][0] = dma_wr_kblock_i;
            bank_d[dma_wr_reg_i][0]    = dma_wr_data_i[255:0];

            bank_cen[dma_wr_reg_i][1]  = 1'b0;
            bank_wen[dma_wr_reg_i][1]  = 1'b0;
            bank_addr[dma_wr_reg_i][1] = dma_wr_kblock_i;
            bank_d[dma_wr_reg_i][1]    = dma_wr_data_i[511:256];
        end

        if (rd0_accept_w) begin
            bank_cen[rd0_reg_i][rd0_row_i]  = 1'b0;
            bank_wen[rd0_reg_i][rd0_row_i]  = 1'b1;
            bank_addr[rd0_reg_i][rd0_row_i] = rd0_kblock_i;
        end

        if (rd1_accept_w) begin
            bank_cen[rd1_reg_i][rd1_row_i]  = 1'b0;
            bank_wen[rd1_reg_i][rd1_row_i]  = 1'b1;
            bank_addr[rd1_reg_i][rd1_row_i] = rd1_kblock_i;
        end
    end

    genvar gen_reg_idx;
    genvar gen_bank_idx;
    generate
        for (gen_reg_idx = 0; gen_reg_idx < 4; gen_reg_idx = gen_reg_idx + 1) begin : g_ab_scale_reg
            for (gen_bank_idx = 0; gen_bank_idx < BANK_COUNT; gen_bank_idx = gen_bank_idx + 1) begin : g_scale_bank
                sram_sp_2x32B u_sram (
                    .Q   ( bank_q[gen_reg_idx][gen_bank_idx]    ),
                    .CLK ( clk                                  ),
                    .CEN ( bank_cen[gen_reg_idx][gen_bank_idx]  ),
                    .WEN ( bank_wen[gen_reg_idx][gen_bank_idx]  ),
                    .A   ( bank_addr[gen_reg_idx][gen_bank_idx] ),
                    .D   ( bank_d[gen_reg_idx][gen_bank_idx]    )
                );
            end
        end
    endgenerate

    // SRAM 同步读后，保存 reg 和 bank，在下一拍输出完整的 32B scale 行。
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
                rd0_bank_q <= rd0_row_i;
            end
            if (rd1_accept_w) begin
                rd1_reg_q  <= rd1_reg_i;
                rd1_bank_q <= rd1_row_i;
            end
        end
    end

    always @* begin
        rd0_scale_o = '0;
        if (rd0_valid_o)
            rd0_scale_o = bank_q[rd0_reg_q][rd0_bank_q];

        rd1_scale_o = '0;
        if (rd1_valid_o)
            rd1_scale_o = bank_q[rd1_reg_q][rd1_bank_q];
    end

endmodule
