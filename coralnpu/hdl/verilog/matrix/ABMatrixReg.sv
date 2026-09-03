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
// rd0 读取指定逻辑行的一个 32B 半行，col=0 选择低 32B，col=1 选择高 32B。
// rd1 支持两种模式：单逻辑行 32B 读，或同一列的相邻两行 64B 读。
module ABMatrixReg (
    input  logic         clk,
    input  logic         rst_n,

    // DMA 每次最多输入一行 64B。有效数据从 dma_wr_data_i[7:0] 开始放置；
    // 若该行不足 64B，DMA 侧必须将其余高字节补零后再写入。
    input  logic         dma_wr_en_i,
    input  logic [1:0]   dma_wr_reg_i,
    input  logic [5:0]   dma_wr_row_i,
    input  logic [511:0] dma_wr_data_i,

    // rd0：读取一个逻辑行的 32B 半行。
    // rd0_addr_i[0] 决定偶数/奇数逻辑行，rd0_addr_i[5:1] 是 SRAM 地址。
    input  logic         rd0_en_i,
    input  logic [1:0]   rd0_reg_i,
    input  logic         rd0_col_i,
    input  logic [5:0]   rd0_addr_i,
    output logic         rd0_valid_o,
    output logic [255:0] rd0_data_o,

    // rd1_col_i 选择半行：0=bank0/2，1=bank1/3。
    // mode=0 读一个逻辑行；mode=1 同时读输入地址对应的偶数行和奇数行。
    input  logic         rd1_en_i,
    input  logic [1:0]   rd1_reg_i,
    input  logic         rd1_mode_i,
    input  logic         rd1_col_i,
    input  logic [5:0]   rd1_addr_i,
    output logic         rd1_valid_o,
    output logic [255:0] rd1_data1_o,
    output logic [255:0] rd1_data2_o
);

    localparam int BANK_COUNT   = 4;

    // bank_* 的第一维选择 4 个 AB 寄存器，第二维选择该寄存器中的 4 个 bank。
    logic [255:0] bank_q    [0:3][0:BANK_COUNT-1];
    logic         bank_cen  [0:3][0:BANK_COUNT-1];
    logic         bank_wen  [0:3][0:BANK_COUNT-1];
    logic [4:0]   bank_addr [0:3][0:BANK_COUNT-1];
    logic [255:0] bank_d    [0:3][0:BANK_COUNT-1];

    logic         rd0_accept_w;
    logic         rd1_accept_w;
    logic         rd0_dma_conflict_w;
    logic         rd1_dma_conflict_w;
    logic         rd01_conflict_w;
    logic [1:0]   rd0_bank_w;
    logic [1:0]   rd1_data1_bank_w;
    logic [1:0]   rd1_data2_bank_w;
    logic [1:0]   rd0_reg_q;
    logic [1:0]   rd0_bank_q;
    logic [1:0]   rd1_reg_q;
    logic         rd1_mode_q;
    logic [1:0]   rd1_data1_bank_q;
    logic [1:0]   rd1_data2_bank_q;

    integer reg_idx;
    integer bank_idx;

    // bank[1] 选择逻辑行奇偶，bank[0] 选择该行的低/高 32B。
    assign rd0_bank_w       = {rd0_addr_i[0], rd0_col_i};
    assign rd1_data1_bank_w = rd1_mode_i ? {1'b0, rd1_col_i} :
                                           {rd1_addr_i[0], rd1_col_i};
    assign rd1_data2_bank_w = {1'b1, rd1_col_i};

    // 同一个物理 bank 是单端口，任何地址上的读写都不能同拍发生。
    assign rd0_dma_conflict_w = dma_wr_en_i && (dma_wr_reg_i == rd0_reg_i);
    assign rd1_dma_conflict_w = dma_wr_en_i && (dma_wr_reg_i == rd1_reg_i);
    assign rd01_conflict_w = rd0_en_i && (rd0_reg_i == rd1_reg_i);
    
    assign rd0_accept_w = rd0_en_i && !rd0_dma_conflict_w;
    assign rd1_accept_w = rd1_en_i && !rd1_dma_conflict_w && !rd01_conflict_w;

    always @* begin
        // 默认关闭全部 bank。CEN/WEN 均为低有效，CEN=1 表示 SRAM 空闲。
        for (reg_idx = 0; reg_idx < 4; reg_idx = reg_idx + 1) begin
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

        // rd0 按逻辑地址打开一个 bank。SRAM 只接收去掉奇偶位后的地址。
        if (rd0_accept_w) begin
            bank_cen[rd0_reg_i][rd0_bank_w]  = 1'b0;
            bank_wen[rd0_reg_i][rd0_bank_w]  = 1'b1;
            bank_addr[rd0_reg_i][rd0_bank_w] = rd0_addr_i[5:1];
        end

        // rd1 mode=0 读取一个逻辑行，mode=1 同时读取同一 SRAM 地址下的偶数/奇数行。
        if (rd1_accept_w) begin
            bank_cen[rd1_reg_i][rd1_data1_bank_w]  = 1'b0;
            bank_wen[rd1_reg_i][rd1_data1_bank_w]  = 1'b1;
            bank_addr[rd1_reg_i][rd1_data1_bank_w] = rd1_addr_i[5:1];

            if (rd1_mode_i) begin
                bank_cen[rd1_reg_i][rd1_data2_bank_w]  = 1'b0;
                bank_wen[rd1_reg_i][rd1_data2_bank_w]  = 1'b1;
                bank_addr[rd1_reg_i][rd1_data2_bank_w] = rd1_addr_i[5:1];
            end
        end
    end

    genvar gen_reg_idx;
    genvar gen_bank_idx;
    generate
        for (gen_reg_idx = 0; gen_reg_idx < 4; gen_reg_idx = gen_reg_idx + 1) begin : g_ab_reg
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
            rd1_data1_bank_q <= '0;
            rd1_data2_bank_q <= '0;
        end else begin
            // SRAM 为同步读，寄存器保存本次的读模式和 bank 选择，供下一拍取数。
            rd0_valid_o <= rd0_accept_w;
            rd1_valid_o <= rd1_accept_w;
            if (rd0_accept_w) begin
                rd0_reg_q  <= rd0_reg_i;
                rd0_bank_q <= rd0_bank_w;
            end
            if (rd1_accept_w) begin
                rd1_reg_q        <= rd1_reg_i;
                rd1_mode_q       <= rd1_mode_i;
                rd1_data1_bank_q <= rd1_data1_bank_w;
                rd1_data2_bank_q <= rd1_data2_bank_w;
            end
        end
    end

    always @* begin
        // rd0 直接输出单 bank 的 32B 数据。
        rd0_data_o = '0;
        if (rd0_valid_o) begin
            rd0_data_o = bank_q[rd0_reg_q][rd0_bank_q];
        end

        // rd1 mode=1 时，data1 输出较小的偶数逻辑行，data2 输出较大的奇数逻辑行。
        // mode=0 时只有 data1 有效，并输出输入地址指定的逻辑行。
        rd1_data1_o = '0;
        rd1_data2_o = '0;
        if (rd1_valid_o) begin
            rd1_data1_o = bank_q[rd1_reg_q][rd1_data1_bank_q];
            if (rd1_mode_q)
                rd1_data2_o = bank_q[rd1_reg_q][rd1_data2_bank_q];
        end
    end

endmodule
