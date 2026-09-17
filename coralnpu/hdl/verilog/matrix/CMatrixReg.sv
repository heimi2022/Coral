`timescale 1ns/1ps

// C 矩阵寄存器文件。
//
// 共 4 个 C Matrix Reg，每个寄存器由 4 个 64 x 64B 的单端口 SRAM bank 组成：
//   bank0：偶数逻辑行的低 64B；
//   bank1：偶数逻辑行的高 64B；
//   bank2：奇数逻辑行的低 64B；
//   bank3：奇数逻辑行的高 64B。
//
// 计算通路每周期读写一个 128B 逻辑行，同时访问同一奇偶组的两个 bank。
// DMA 通路每周期写入 64B，dma_wr_half_i 选择逻辑行的低/高 64B。
//
// wr_addr_i/rd_addr_i/dma_wr_addr_i 是 0~63 的逻辑行地址：
//   addr[0]=0 使用 bank0/1，addr[0]=1 使用 bank2/3；
//   addr[5:1] 是 SRAM 内当前 N block 的 0~31 行地址。
// C 的形状为 M x N；32-bit 元素下，每个 N block 包含 32 列。
// nblock=0 时访问 SRAM 低 32 行，存放 N[0:31]；
// nblock=1 时访问 SRAM 高 32 行，存放 N[32:63]。
// 因此最终 SRAM 地址为 {nblock, addr[5:1]}。
//
// SRAM 为单端口结构，访问优先级为 DMA 写 > 计算写回 > 计算读。
// 不同 C reg 或同一 C reg 的不同奇偶 bank 组仍可在同一周期并行访问。
module CMatrixReg (
    input  logic          clk,
    input  logic          rst_n,

    // mzero 只清除状态位，不访问 SRAM；mask 每位对应一个 C 寄存器。
    input  logic          c_reg_clear_valid_i,
    input  logic [3:0]    c_reg_clear_mask_i,
    // DMA LOAD C 或 PE 整条矩阵乘法完成后，提交对应 C reg 为有效。
    input  logic          c_reg_commit_valid_i,
    input  logic [3:0]    c_reg_commit_mask_i,
    // 0：处于逻辑清零状态；1：该寄存器已提交为有效。
    output logic [3:0]    c_reg_zero_n_o,

    // 计算写回端口：每周期写入一个 128B 逻辑行。
    input  logic          wr_en_i,
    input  logic [1:0]    wr_reg_i,
    input  logic [5:0]    wr_addr_i,
    input  logic          wr_nblock_i,
    input  logic [1023:0] wr_data_i,

    // DMA 写端口：每周期写入一个 64B bank。
    input  logic          dma_wr_en_i,
    input  logic [1:0]    dma_wr_reg_i,
    input  logic [5:0]    dma_wr_addr_i,
    input  logic          dma_wr_nblock_i,
    input  logic          dma_wr_half_i,
    input  logic [511:0]  dma_wr_data_i,

    // DMA 读端口：每周期读取一个 64B bank。
    input  logic          dma_rd_en_i,
    input  logic [1:0]    dma_rd_reg_i,
    input  logic [5:0]    dma_rd_addr_i,
    input  logic          dma_rd_nblock_i,
    input  logic          dma_rd_half_i,
    output logic          dma_rd_valid_o,
    output logic [511:0]  dma_rd_data_o,

    // 计算读端口：每周期读取一个 128B 逻辑行。
    // SRAM 为同步读，读数据在接受请求后的一个时钟周期有效。
    input  logic          rd_en_i,
    input  logic [1:0]    rd_reg_i,
    input  logic [5:0]    rd_addr_i,
    input  logic          rd_nblock_i,
    output logic          rd_valid_o,
    output logic [1023:0] rd_data_o
);

    localparam int BANK_COUNT = 4;

    logic [3:0] c_reg_zero_n;
    logic [3:0] c_reg_clear_mask;
    logic [3:0] c_reg_commit_mask;
    logic       c_reg_state_update;
    logic [511:0] bank_q    [0:3][0:BANK_COUNT-1];
    logic         bank_cen  [0:3][0:BANK_COUNT-1];
    logic         bank_wen  [0:3][0:BANK_COUNT-1];
    logic [5:0]   bank_addr [0:3][0:BANK_COUNT-1];
    logic [511:0] bank_d    [0:3][0:BANK_COUNT-1];

    logic         wr_accept_w;
    logic         rd_accept_w;
    logic         wr_dma_conflict_w;
    logic         rd_wr_conflict_w;
    logic         rd_dma_conflict_w;
    logic         dma_rd_accept_w;
    logic [5:0]   wr_sram_addr_w;
    logic [5:0]   dma_wr_sram_addr_w;
    logic [5:0]   rd_sram_addr_w;
    logic [1:0]   dma_wr_bank_w;
    logic [5:0]   dma_rd_sram_addr_w;
    logic [1:0]   dma_rd_bank_w;

    logic [1:0]   rd_reg_q;
    logic         rd_odd_q;
    logic [1:0]   dma_rd_reg_q;
    logic [1:0]   dma_rd_bank_q;

    integer reg_idx;
    integer bank_idx;

    // 寄存器清零逻辑
    // 0：逻辑清零状态；1：整条指令已提交。物理写入不改变标志，提交优先于清除。
    assign c_reg_clear_mask = c_reg_clear_mask_i & {4{c_reg_clear_valid_i}};
    assign c_reg_commit_mask = c_reg_commit_mask_i & {4{c_reg_commit_valid_i}};
    assign c_reg_state_update = c_reg_clear_valid_i || c_reg_commit_valid_i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            c_reg_zero_n <= '0;
        else if (c_reg_state_update)
            c_reg_zero_n <= (c_reg_zero_n & ~c_reg_clear_mask) | c_reg_commit_mask;
    end
    assign c_reg_zero_n_o = c_reg_zero_n;
    
    // 每个 bank 的低/高 32 行分别存放低/高 N block。
    assign wr_sram_addr_w     = {wr_nblock_i,     wr_addr_i[5:1]};
    assign dma_wr_sram_addr_w = {dma_wr_nblock_i, dma_wr_addr_i[5:1]};
    assign rd_sram_addr_w     = {rd_nblock_i,     rd_addr_i[5:1]};
    assign dma_rd_sram_addr_w = {dma_rd_nblock_i, dma_rd_addr_i[5:1]};

    // bank[1] 选择逻辑行奇偶，bank[0] 选择该行的低/高 64B。
    assign dma_wr_bank_w = {dma_wr_addr_i[0], dma_wr_half_i};

    // 计算写回需要同时占用同一奇偶组的两个 bank；与 DMA 冲突时 DMA 优先。
    assign wr_dma_conflict_w = dma_wr_en_i &&
                               (dma_wr_reg_i == wr_reg_i) &&
                               (dma_wr_addr_i[0] == wr_addr_i[0]);
    assign wr_accept_w = wr_en_i && !wr_dma_conflict_w;

    // 计算读也需要两个 bank，只要任一写端口访问同一 reg、同一奇偶组就不能接受。
    assign rd_dma_conflict_w = dma_wr_en_i &&
                               (dma_wr_reg_i == rd_reg_i) &&
                               (dma_wr_addr_i[0] == rd_addr_i[0]);
    assign rd_wr_conflict_w = wr_accept_w &&
                              (wr_reg_i == rd_reg_i) &&
                              (wr_addr_i[0] == rd_addr_i[0]);
    assign rd_accept_w = rd_en_i && !rd_dma_conflict_w && !rd_wr_conflict_w;
    assign dma_rd_bank_w = {dma_rd_addr_i[0], dma_rd_half_i};
    assign dma_rd_accept_w = dma_rd_en_i &&
                             !(wr_accept_w &&
                               (wr_reg_i == dma_rd_reg_i) &&
                               (wr_addr_i[0] == dma_rd_addr_i[0])) &&
                             !(dma_wr_en_i &&
                               (dma_wr_reg_i == dma_rd_reg_i) &&
                               (dma_wr_addr_i[0] == dma_rd_addr_i[0]) &&
                               (dma_wr_half_i == dma_rd_half_i)) &&
                             !(rd_en_i &&
                               (rd_reg_i == dma_rd_reg_i) &&
                               (rd_addr_i[0] == dma_rd_addr_i[0]));

    // 默认关闭所有 bank。CEN/WEN 均为低有效。
    always @* begin
        for (reg_idx = 0; reg_idx < 4; reg_idx = reg_idx + 1) begin
            for (bank_idx = 0; bank_idx < BANK_COUNT; bank_idx = bank_idx + 1) begin
                bank_cen[reg_idx][bank_idx]  = 1'b1;
                bank_wen[reg_idx][bank_idx]  = 1'b1;
                bank_addr[reg_idx][bank_idx] = '0;
                bank_d[reg_idx][bank_idx]    = '0;
            end
        end

        // 计算结果的低/高 64B 分别写入当前奇偶组的两个 bank。
        if (wr_accept_w) begin
            for (bank_idx = 0; bank_idx < 2; bank_idx = bank_idx + 1) begin
                bank_cen[wr_reg_i][{wr_addr_i[0], bank_idx[0]}]  = 1'b0;
                bank_wen[wr_reg_i][{wr_addr_i[0], bank_idx[0]}]  = 1'b0;
                bank_addr[wr_reg_i][{wr_addr_i[0], bank_idx[0]}] = wr_sram_addr_w;
                bank_d[wr_reg_i][{wr_addr_i[0], bank_idx[0]}] =
                    wr_data_i[bank_idx * 512 +: 512];
            end
        end

        // 读请求同时打开当前奇偶组的两个 64B bank。
        if (rd_accept_w) begin
            for (bank_idx = 0; bank_idx < 2; bank_idx = bank_idx + 1) begin
                bank_cen[rd_reg_i][{rd_addr_i[0], bank_idx[0]}]  = 1'b0;
                bank_wen[rd_reg_i][{rd_addr_i[0], bank_idx[0]}]  = 1'b1;
                bank_addr[rd_reg_i][{rd_addr_i[0], bank_idx[0]}] = rd_sram_addr_w;
            end
        end

        // DMA 写优先级最高，一拍只写当前逻辑行选中的一个 64B bank。
        if (dma_wr_en_i) begin
            bank_cen[dma_wr_reg_i][dma_wr_bank_w]  = 1'b0;
            bank_wen[dma_wr_reg_i][dma_wr_bank_w]  = 1'b0;
            bank_addr[dma_wr_reg_i][dma_wr_bank_w] = dma_wr_sram_addr_w;
            bank_d[dma_wr_reg_i][dma_wr_bank_w]    = dma_wr_data_i;
        end

        if (dma_rd_accept_w) begin
            bank_cen[dma_rd_reg_i][dma_rd_bank_w] = 1'b0;
            bank_wen[dma_rd_reg_i][dma_rd_bank_w] = 1'b1;
            bank_addr[dma_rd_reg_i][dma_rd_bank_w] = dma_rd_sram_addr_w;
        end
    end

    genvar gen_reg_idx;
    genvar gen_bank_idx;
    generate
        for (gen_reg_idx = 0; gen_reg_idx < 4; gen_reg_idx = gen_reg_idx + 1) begin : g_c_reg
            for (gen_bank_idx = 0; gen_bank_idx < BANK_COUNT; gen_bank_idx = gen_bank_idx + 1) begin : g_bank
                // 每个 bank 为 64 行 x 64B 的单端口 SRAM。
                sram_sp #(
                    .DATA_WIDTH ( 512 ),
                    .DEPTH      ( 64  ),
                    .ADDR_WIDTH ( 6   )
                ) u_sram (
                    .Q    ( bank_q[gen_reg_idx][gen_bank_idx]    ),
                    .CLK  ( clk                                   ),
                    .CEN  ( bank_cen[gen_reg_idx][gen_bank_idx]  ),
                    .WEN  ( bank_wen[gen_reg_idx][gen_bank_idx]  ),
                    .A    ( bank_addr[gen_reg_idx][gen_bank_idx] ),
                    .D    ( bank_d[gen_reg_idx][gen_bank_idx]    ),
                    .EMA  ( 3'b000                                ),
                    .EMAW ( 2'b00                                 ),
                    .EMAS ( 1'b0                                  ),
                    .RET1N( 1'b1                                  )
                );
            end
        end
    endgenerate

    // 同步读的控制信息打一拍，与 SRAM Q 的新数据对应。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_valid_o <= 1'b0;
            dma_rd_valid_o <= 1'b0;
            rd_reg_q   <= '0;
            rd_odd_q   <= 1'b0;
            dma_rd_reg_q  <= '0;
            dma_rd_bank_q <= '0;
        end else begin
            rd_valid_o <= rd_accept_w;
            dma_rd_valid_o <= dma_rd_accept_w;
            if (rd_accept_w) begin
                rd_reg_q <= rd_reg_i;
                rd_odd_q <= rd_addr_i[0];
            end
            if (dma_rd_accept_w) begin
                dma_rd_reg_q  <= dma_rd_reg_i;
                dma_rd_bank_q <= dma_rd_bank_w;
            end
        end
    end

    always @* begin
        dma_rd_data_o = '0;
        if (dma_rd_valid_o)
            dma_rd_data_o = bank_q[dma_rd_reg_q][dma_rd_bank_q];
    end

    // bank0/2 输出低 64B，bank1/3 输出高 64B。
    always @* begin
        rd_data_o = '0;
        if (rd_valid_o) begin
            rd_data_o[511:0] = bank_q[rd_reg_q][{rd_odd_q, 1'b0}];
            rd_data_o[1023:512] = bank_q[rd_reg_q][{rd_odd_q, 1'b1}];
        end
    end

endmodule
