`timescale 1ns/1ps

// C 矩阵寄存器文件。
//
// 共 4 个 C Matrix Reg，每个寄存器由 8 个 64 x 32B 的单端口 SRAM bank 组成：
//   bank0~bank3：存储偶数行，每行由 4 个 bank 拼成 128B；
//   bank4~bank7：存储奇数行，每行由 4 个 bank 拼成 128B。
//
// 一次读写操作的粒度均为 128B：
//   data[255:0]    -> 当前行的第 0 个 32B；
//   data[511:256]  -> 当前行的第 1 个 32B；
//   data[767:512]  -> 当前行的第 2 个 32B；
//   data[1023:768] -> 当前行的第 3 个 32B。
//
// wr_addr_i/rd_addr_i 是 0~63 的逻辑行地址：
//   addr[0]=0 使用 bank0~3，addr[0]=1 使用 bank4~7；
//   addr[5:1] 是 SRAM 内当前 K block 的 0~31 行地址。
// kblock=0 时访问 SRAM 低 32 行，kblock=1 时访问 SRAM 高 32 行，
// 因此最终 SRAM 地址为 {kblock, addr[5:1]}。
//
// SRAM 为单端口结构。同一个 C reg 的同一奇偶 bank 组不能同时读写；
// 冲突时写操作优先，本次读不会产生 valid。偶数行写回与奇数行读取
// 使用不同 bank 组，可以在同一周期进行。
module CMatrixReg (
    input  logic         clk            ,
    input  logic         rst_n          ,

    // C 矩阵写端口：每周期写入一个 128B 行。
    input  logic          wr_en_i       ,
    input  logic [1:0]    wr_reg_i      ,
    input  logic [5:0]    wr_addr_i     ,
    input  logic          wr_kblock_i   ,
    input  logic [1023:0] wr_data_i     ,

    // C 矩阵读端口：每周期读取一个 128B 行。
    // SRAM 为同步读，读数据在接受请求后的一个时钟周期有效。
    input  logic          rd_en_i       ,
    input  logic [1:0]    rd_reg_i      ,
    input  logic [5:0]    rd_addr_i     ,
    input  logic          rd_kblock_i   ,  
    output logic          rd_valid_o    ,
    output logic [1023:0] rd_data_o      
);

    localparam int BANK_COUNT = 8;

    logic [255:0] bank_q    [0:3][0:BANK_COUNT-1];
    logic         bank_cen  [0:3][0:BANK_COUNT-1];
    logic         bank_wen  [0:3][0:BANK_COUNT-1];
    logic [5:0]   bank_addr [0:3][0:BANK_COUNT-1];
    logic [255:0] bank_d    [0:3][0:BANK_COUNT-1];

    logic         rd_accept_w;
    logic         rd_conflict_w;
    logic [5:0]   rd_sram_addr_w;
    logic [5:0]   wr_sram_addr_w;

    logic [1:0]   rd_reg_q;
    logic         rd_odd_q;

    integer reg_idx;
    integer bank_idx;
    integer data_idx;

    // 每个 bank 的低/高 32 行分别存放低/高 K block。
    assign rd_sram_addr_w = {rd_kblock_i, rd_addr_i[5:1]};
    assign wr_sram_addr_w = {wr_kblock_i, wr_addr_i[5:1]};

    // 同一个 C reg 的同一奇偶组会访问同一批单端口 SRAM bank。
    assign rd_conflict_w = wr_en_i &&
                           (wr_reg_i == rd_reg_i) &&
                           (wr_addr_i[0] == rd_addr_i[0]);
    assign rd_accept_w   = rd_en_i && !rd_conflict_w;

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

        // 一次写入 128B，拆成 4 个 32B bank 写入。
        if (wr_en_i) begin
            for (bank_idx = 0; bank_idx < 4; bank_idx = bank_idx + 1) begin
                bank_cen[wr_reg_i][{wr_addr_i[0], bank_idx[1:0]}]  = 1'b0;
                bank_wen[wr_reg_i][{wr_addr_i[0], bank_idx[1:0]}]  = 1'b0;
                bank_addr[wr_reg_i][{wr_addr_i[0], bank_idx[1:0]}] = wr_sram_addr_w;
                bank_d[wr_reg_i][{wr_addr_i[0], bank_idx[1:0]}] =
                    wr_data_i[bank_idx * 256 +: 256];
            end
        end

        // 读请求不能与同一 reg、同一奇偶组的写请求同时访问。
        if (rd_accept_w) begin
            for (bank_idx = 0; bank_idx < 4; bank_idx = bank_idx + 1) begin
                bank_cen[rd_reg_i][{rd_addr_i[0], bank_idx[1:0]}]  = 1'b0;
                bank_wen[rd_reg_i][{rd_addr_i[0], bank_idx[1:0]}]  = 1'b1;
                bank_addr[rd_reg_i][{rd_addr_i[0], bank_idx[1:0]}] = rd_sram_addr_w;
            end
        end
    end

    genvar gen_reg_idx;
    genvar gen_bank_idx;
    generate
        for (gen_reg_idx = 0; gen_reg_idx < 4; gen_reg_idx = gen_reg_idx + 1) begin : g_c_reg
            for (gen_bank_idx = 0; gen_bank_idx < BANK_COUNT; gen_bank_idx = gen_bank_idx + 1) begin : g_bank
                // 每个 bank 为 64 行 x 32B 的单端口 SRAM。
                sram_sp #(
                    .DATA_WIDTH ( 256 ),
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
            rd_reg_q   <= '0;
            rd_odd_q   <= 1'b0;
        end else begin
            rd_valid_o <= rd_accept_w;
            if (rd_accept_w) begin
                rd_reg_q <= rd_reg_i;
                rd_odd_q <= rd_addr_i[0];
            end
        end
    end

    // 将同一奇偶行组的 4 个 32B bank 拼回 128B 输出。
    always @* begin
        rd_data_o = '0;
        if (rd_valid_o) begin
            for (data_idx = 0; data_idx < 4; data_idx = data_idx + 1) begin
                rd_data_o[data_idx * 256 +: 256] =
                    bank_q[rd_reg_q][{rd_odd_q, data_idx[1:0]}];
            end
        end
    end

endmodule
