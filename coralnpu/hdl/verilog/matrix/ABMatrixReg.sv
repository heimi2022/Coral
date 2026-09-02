`timescale 1ns/1ps

// AB 矩阵寄存器文件：共 4 个寄存器，每个寄存器容量为 64 行 x 64B。
// 一个寄存器由四个 32 行 x 32B 的单端口 SRAM bank 组成。
//
// 64B 逻辑行在两个 bank 对之间按行交错存储：
//   偶数行：bank0 存低 32B，bank1 存高 32B。
//   奇数行：bank2 存低 32B，bank3 存高 32B。
// SRAM 行地址等于逻辑行号除以 2，即 row[5:1]。
//
// 两个读口均为一拍延迟；单端口冲突的优先级为：DMA 写 > rd0 > rd1。
// rd0 固定读取指定的一个 bank 的一行，输出低 32B 有效。
// rd1 支持两种模式：单 bank 32B 读，或同列双 bank 64B 读。
module ABMatrixReg (
    input  logic         clk,
    input  logic         rst_n,

    // DMA 每次最多输入一行 64B。有效数据从 dma_wr_data_i[7:0] 开始放置；
    // 若该行不足 64B，DMA 侧必须将其余高字节补零后再写入。
    input  logic         dma_wr_en_i,
    input  logic [1:0]   dma_wr_reg_i,
    input  logic [5:0]   dma_wr_row_i,
    input  logic [511:0] dma_wr_data_i,

    // rd0：固定单 bank 读，rd0_bank_i 选择 bank0~3。
    input  logic         rd0_en_i,
    input  logic [1:0]   rd0_reg_i,
    input  logic [1:0]   rd0_bank_i,
    input  logic [4:0]   rd0_addr_i,
    output logic         rd0_valid_o,
    output logic [255:0] rd0_data_o,

    // rd1：mode=0 时 rd1_bank_i 选择 bank0~3；mode=1 时 rd1_col_i 选择：
    // 0=bank0+bank2，1=bank1+bank3。
    input  logic         rd1_en_i,
    input  logic [1:0]   rd1_reg_i,
    input  logic         rd1_mode_i,
    input  logic [1:0]   rd1_bank_i,
    input  logic         rd1_col_i,
    input  logic [4:0]   rd1_addr_i,
    output logic         rd1_valid_o,
    output logic [511:0] rd1_data_o
);

    localparam int AB_REG_COUNT = 4;
    localparam int BANK_COUNT   = 4;

    // bank_* 的第一维选择 4 个 AB 寄存器，第二维选择该寄存器中的 4 个 bank。
    logic [255:0] bank_q    [0:AB_REG_COUNT-1][0:BANK_COUNT-1];
    logic         bank_cen  [0:AB_REG_COUNT-1][0:BANK_COUNT-1];
    logic         bank_wen  [0:AB_REG_COUNT-1][0:BANK_COUNT-1];
    logic [4:0]   bank_addr [0:AB_REG_COUNT-1][0:BANK_COUNT-1];
    logic [255:0] bank_d    [0:AB_REG_COUNT-1][0:BANK_COUNT-1];

    logic         rd0_accept_w;
    logic         rd1_accept_w;
    logic         rd0_dma_conflict_w;
    logic         rd1_dma_conflict_w;
    logic         rd01_conflict_w;
    logic [3:0]   dma_bank_mask_w;
    logic [3:0]   rd0_bank_mask_w;
    logic [3:0]   rd1_bank_mask_w;
    logic [1:0]   rd0_reg_q;
    logic [1:0]   rd0_bank_q;
    logic [1:0]   rd1_reg_q;
    logic         rd1_mode_q;
    logic [1:0]   rd1_bank_q;
    logic         rd1_col_q;

    integer reg_idx;
    integer bank_idx;

    // 将读模式转换为物理 bank 使能掩码。mode=1 选择同一列的两个 bank。
    function automatic [3:0] read_bank_mask;
        input       mode;
        input [1:0] bank;
        input       col;
        begin
            if (mode) begin
                read_bank_mask = col ? 4'b1010 : 4'b0101;
            end else begin
                read_bank_mask = 4'b0000;
                read_bank_mask[bank] = 1'b1;
            end
        end
    endfunction

    // DMA 根据逻辑行的奇偶一次占用一个 bank 对。
    assign dma_bank_mask_w = dma_wr_row_i[0] ? 4'b1100 : 4'b0011;
    assign rd0_bank_mask_w = read_bank_mask(1'b0, rd0_bank_i, 1'b0);
    assign rd1_bank_mask_w = read_bank_mask(rd1_mode_i, rd1_bank_i, rd1_col_i);

    // 同一个物理 bank 是单端口，任何地址上的读写都不能同拍发生。
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
        // 默认关闭全部 bank。CEN/WEN 均为低有效，CEN=1 表示 SRAM 空闲。
        for (reg_idx = 0; reg_idx < AB_REG_COUNT; reg_idx = reg_idx + 1) begin
            for (bank_idx = 0; bank_idx < BANK_COUNT; bank_idx = bank_idx + 1) begin
                bank_cen[reg_idx][bank_idx]  = 1'b1;
                bank_wen[reg_idx][bank_idx]  = 1'b1;
                bank_addr[reg_idx][bank_idx] = '0;
                bank_d[reg_idx][bank_idx]    = '0;
            end
        end

        // DMA 写一行时同时写一对 bank：row[0] 决定使用哪一对，
        // row[5:1] 是该对 bank 内的 0~31 行地址。
        if (dma_wr_en_i) begin
            bank_cen[dma_wr_reg_i][dma_wr_row_i[0] ? 2 : 0]  = 1'b0;
            bank_wen[dma_wr_reg_i][dma_wr_row_i[0] ? 2 : 0]  = 1'b0;
            bank_addr[dma_wr_reg_i][dma_wr_row_i[0] ? 2 : 0] = dma_wr_row_i[5:1];
            bank_d[dma_wr_reg_i][dma_wr_row_i[0] ? 2 : 0]    = dma_wr_data_i[255:0];

            bank_cen[dma_wr_reg_i][dma_wr_row_i[0] ? 3 : 1]  = 1'b0;
            bank_wen[dma_wr_reg_i][dma_wr_row_i[0] ? 3 : 1]  = 1'b0;
            bank_addr[dma_wr_reg_i][dma_wr_row_i[0] ? 3 : 1] = dma_wr_row_i[5:1];
            bank_d[dma_wr_reg_i][dma_wr_row_i[0] ? 3 : 1]    = dma_wr_data_i[511:256];
        end

        // rd0 根据模式打开一个或两个 bank，地址均为 rd0_addr_i。
        if (rd0_accept_w) begin
            for (bank_idx = 0; bank_idx < BANK_COUNT; bank_idx = bank_idx + 1) begin
                if (rd0_bank_mask_w[bank_idx]) begin
                    bank_cen[rd0_reg_i][bank_idx]  = 1'b0;
                    bank_wen[rd0_reg_i][bank_idx]  = 1'b1;
                    bank_addr[rd0_reg_i][bank_idx] = rd0_addr_i;
                end
            end
        end

        // rd1 可使用未被 DMA 和 rd0 占用的 bank 并行读取。
        if (rd1_accept_w) begin
            for (bank_idx = 0; bank_idx < BANK_COUNT; bank_idx = bank_idx + 1) begin
                if (rd1_bank_mask_w[bank_idx]) begin
                    bank_cen[rd1_reg_i][bank_idx]  = 1'b0;
                    bank_wen[rd1_reg_i][bank_idx]  = 1'b1;
                    bank_addr[rd1_reg_i][bank_idx] = rd1_addr_i;
                end
            end
        end
    end

    genvar gen_reg_idx;
    genvar gen_bank_idx;
    generate
        for (gen_reg_idx = 0; gen_reg_idx < AB_REG_COUNT; gen_reg_idx = gen_reg_idx + 1) begin : g_ab_reg
            for (gen_bank_idx = 0; gen_bank_idx < BANK_COUNT; gen_bank_idx = gen_bank_idx + 1) begin : g_bank
                // 4 个寄存器 x 每个寄存器 4 个 bank，共 16 个 SRAM 宏实例。
                sram_sp_32x32B u_sram (
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
            rd0_valid_o      <= 1'b0;
            rd0_reg_q        <= '0;
            rd0_bank_q       <= '0;
            rd1_valid_o      <= 1'b0;
            rd1_reg_q        <= '0;
            rd1_mode_q       <= 1'b0;
            rd1_bank_q       <= '0;
            rd1_col_q        <= 1'b0;
        end else begin
            // SRAM 为同步读，寄存器保存本次的读模式和 bank 选择，供下一拍取数。
            rd0_valid_o <= rd0_accept_w;
            rd1_valid_o <= rd1_accept_w;
            if (rd0_accept_w) begin
                rd0_reg_q  <= rd0_reg_i;
                rd0_bank_q <= rd0_bank_i;
            end
            if (rd1_accept_w) begin
                rd1_reg_q  <= rd1_reg_i;
                rd1_mode_q <= rd1_mode_i;
                rd1_bank_q <= rd1_bank_i;
                rd1_col_q  <= rd1_col_i;
            end
        end
    end

    always @* begin
        // rd0 直接输出单 bank 的 32B 数据。
        rd0_data_o = '0;
        if (rd0_valid_o) begin
            rd0_data_o = bank_q[rd0_reg_q][rd0_bank_q];
        end

        // rd1：mode=0 的 32B 放在低位；mode=1 拼接同一列的两个 bank。
        rd1_data_o = '0;
        if (rd1_valid_o) begin
            if (rd1_mode_q) begin
                rd1_data_o = rd1_col_q ?
                    {bank_q[rd1_reg_q][3], bank_q[rd1_reg_q][1]} :
                    {bank_q[rd1_reg_q][2], bank_q[rd1_reg_q][0]};
            end else begin
                rd1_data_o[255:0] = bank_q[rd1_reg_q][rd1_bank_q];
            end
        end
    end

endmodule
