/*
矩阵 load 子模块

这一版按“ABMatrixReg 由多个 256b SRAM bank 组成”来设计：
1. issue 路：
   - stride == row_bytes 且不跨4KB边界时，整条 DMA 合并为一个 burst
   - 其它情况保持每行一个 burst，并允许多个行请求在途
2. receive / ABMatrixReg-write 路：
   - AXI R 通道按单 ID、按序返回
   - 返回 beat 的有效字节先压紧并追加到 128B 流缓冲
   - 流缓冲按 row_bytes 逐行取数，一拍包含多行时分多个周期写入 ABMatrixReg
   - 每行不足 64B 的高字节在 AB 写口补零

说明：
1. 请求发射与返回写入独立推进，多条 load 可以同时在途；两侧均保持命令顺序
2. 当前使用单 AXI ID，不支持乱序返回；依赖 AXI 对同 ID 返回顺序的保证
3. 当前 fault 语义偏硬件直写风格：
   - 检测到 burst error 后停止该命令的寄存器写入，继续发完并排空该命令的请求
   - 已经直写进矩阵寄存器的 beat 不回滚

！ RISCV 拓展中 转置指令暂时不考虑，若做转置需要额外大量寄存器开销，或者在一整条DMA指令中对数据分块进行转置。
*/

module MatrixDmaLoad #(
    parameter int AXI_ADDR = 32,
    parameter int AXI_DATA = 512,
    parameter int AXI_ID   = 1,
    parameter int REG_IDX  = 2,
    // 暂时保留以兼容现有 MatrixDma 实例；AB 写路径不再使用该参数。
    parameter int REG_BEAT = $clog2((4096 + (AXI_DATA / 8) - 1) / (AXI_DATA / 8)),
    // AB 行最大 64B，C 行最大 256B，需要 9 位表示行字节数。
    parameter int ROW_BYTE_W = 9,
    parameter int CMD_QUEUE_DEPTH = 3,
    parameter int READ_OUTSTANDING_DEPTH = 4
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // ------------------------------------------------------------------------
    // 归一化后的矩阵 load 命令输入。
    // 语义：
    // 1. mem_rows_i 表示本条命令包含的逻辑行数
    // 2. mem_cols_i * elem_bytes 在命令入队时计算为单行有效字节数
    // 3. stride == row_bytes 时连续行可合并，否则第 i 行地址 = base + i * stride
    // ------------------------------------------------------------------------
    input  logic                     mem_valid_i,
    output logic                     mem_ready_o,
    input  logic [31:0]              mem_pc_i,
    input  logic [2:0]               mem_reg_i,
    input  logic                     mem_ab_scale_sel_i, // 0: ABMatrixReg，1: ABScaleReg
    input  logic [1:0]               mem_elem_bytes_i,  // 0: 1 byte, 1: 2 bytes, 2: 4 bytes
    input  logic [31:0]              mem_base_i,
    input  logic [31:0]              mem_stride_i,
    input  logic [7:0]               mem_rows_i,
    input  logic [7:0]               mem_cols_i,

    // ------------------------------------------------------------------------
    // 返回给顶层的 load 子系统状态。
    // ------------------------------------------------------------------------
    output logic                     busy_o,
    output logic                     done_valid_o,
    output logic                     done_fault_o,
    output logic [31:0]              done_pc_o,
    output logic [31:0]              done_fault_addr_o,

    // ------------------------------------------------------------------------
    // AB 数据/scale 寄存器写口。一次写入一个逻辑行，数据宽度固定为一个
    // AXI beat（当前64B）；ABScaleReg 将 scale 数据拆成两个 256-bit bank 行。
    // ------------------------------------------------------------------------
    output logic                     ab_wr_en_o,
    output logic [REG_IDX-1:0]       ab_wr_reg_o,
    output logic [5:0]               ab_wr_row_o,
    output logic [AXI_DATA-1:0]      ab_wr_data_o,
    output logic                     ab_wr_dst_sel_o,
    output logic                     c_wr_en_o,
    output logic                     c_wr_half_o,
    output logic                     c_wr_nblock_o,

    // ------------------------------------------------------------------------
    // AXI 读 master 口。
    // ------------------------------------------------------------------------
    output logic                     m_axi_arvalid_o,
    input  logic                     m_axi_arready_i,
    output logic [AXI_ID-1:0]        m_axi_arid_o,
    output logic [AXI_ADDR-1:0]      m_axi_araddr_o,
    output logic [7:0]               m_axi_arlen_o,
    output logic [2:0]               m_axi_arsize_o,
    output logic [1:0]               m_axi_arburst_o,

    input  logic                     m_axi_rvalid_i,
    output logic                     m_axi_rready_o,
    input  logic [AXI_ID-1:0]        m_axi_rid_i,
    input  logic [AXI_DATA-1:0]      m_axi_rdata_i,
    input  logic [1:0]               m_axi_rresp_i,
    input  logic                     m_axi_rlast_i
);

    localparam int AXI_STRB = AXI_DATA / 8;
    localparam int AXI_BEAT_LG2 = $clog2(AXI_STRB);
    localparam int STREAM_BUFFER_BYTES = AXI_STRB * 2;
    localparam int STREAM_COUNT_W = $clog2(STREAM_BUFFER_BYTES + 1);
    localparam int BURST_BYTE_W = 13;
    localparam int DMA_TOTAL_BYTE_W = 15;
    // reg(3) + dst_sel(1) + row_bytes + base(32) + stride(32) + rows(8)
    localparam int CMD_DATA = 76 + ROW_BYTE_W;
    // 接收侧只需知道目标寄存器、目的类型、行大小和总行数，不携带地址或 stride。
    localparam int INFLIGHT_DATA = 12 + ROW_BYTE_W;
    // 限制已接收但尚未完成的 LOAD 总数，包含排队、发射及接收中的命令。
    localparam int PC_QUEUE_DEPTH = CMD_QUEUE_DEPTH + 1;
    logic [31:0] pc_fifo_data_out;
    logic pc_fifo_full;
    logic pc_fifo_pop;

    logic [CMD_DATA-1:0]           issue_cmd_fifo_data_in;
    logic [CMD_DATA-1:0]           issue_cmd_fifo_rd_data;
    logic                          issue_cmd_fifo_full;
    logic                          issue_cmd_fifo_empty;
    logic                          issue_cmd_push;
    logic                          issue_cmd_pop;

    logic [2:0]                    issue_cmd_fifo_reg;
    logic                          issue_cmd_fifo_dst_sel;
    logic [ROW_BYTE_W-1:0]         issue_cmd_fifo_row_bytes;
    logic [31:0]                   issue_cmd_fifo_base;
    logic [31:0]                   issue_cmd_fifo_stride;
    logic [7:0]                    issue_cmd_fifo_rows;
    logic [DMA_TOTAL_BYTE_W-1:0]   issue_cmd_fifo_total_bytes;
    logic [12:0]                   issue_cmd_fifo_4k_bytes_left;
    logic                          issue_cmd_fifo_contiguous;

    logic [INFLIGHT_DATA-1:0]      inflight_fifo_data_in;
    logic [INFLIGHT_DATA-1:0]      inflight_fifo_rd_data;
    logic                          inflight_fifo_full;
    logic                          inflight_fifo_empty;
    logic                          inflight_cmd_pop;

    logic [2:0]                    inflight_fifo_reg;
    logic                          inflight_fifo_dst_sel;
    logic [ROW_BYTE_W-1:0]         inflight_fifo_row_bytes;
    logic [7:0]                    inflight_fifo_rows;

    logic                          issue_cmd_active;
    logic [ROW_BYTE_W-1:0]         issue_cmd_row_bytes;
    logic [31:0]                   issue_cmd_stride;
    logic [7:0]                    issue_cmd_rows;
    logic [DMA_TOTAL_BYTE_W-1:0]   issue_cmd_total_bytes;
    logic [12:0]                   issue_cmd_4k_bytes_left;
    logic                          issue_cmd_contiguous;
    logic                          issue_cmd_merge_rows;

    logic                          recv_cmd_active;
    logic                          recv_cmd_fault_seen;
    logic                          recv_cmd_data_done;
    logic [2:0]                    recv_cmd_reg;
    logic                          recv_cmd_dst_sel;
    logic [ROW_BYTE_W-1:0]         recv_cmd_row_bytes;
    logic [7:0]                    recv_cmd_rows;
    logic [31:0]                   issue_addr;
    logic [ROW_BYTE_W-1:0]         issue_row_offset;
    logic [12:0]                   issue_page_left;
    logic                          issue_row_last;
    logic [ROW_BYTE_W-1:0]         recv_row_offset;
    logic [ROW_BYTE_W-1:0]         recv_chunk_bytes;
    logic                          recv_chunk_last;

    logic [7:0]                    bursts_issued;
    logic [7:0]                    rows_received;

    // AB 寄存器编号。mem_reg[2] 的类别检查后续在上游或 DMA 顶层处理。
    logic [REG_IDX-1:0]            recv_cmd_reg_idx;
    logic [BURST_BYTE_W-1:0]       cmd_burst_byte_num;
    logic [ROW_BYTE_W-1:0]         mem_row_byte_num;

    logic                          read_burst_valid;
    logic                          read_burst_fire;
    logic                          issue_cmd_done;
    logic                          issue_has_request;
    logic                          issue_request_last;

    logic                          read_req_busy;
    logic                          read_busy;
    logic                          read_beat_valid;
    logic                          read_beat_first;
    logic                          read_beat_last;
    logic                          read_cmd_last;
    logic [AXI_BEAT_LG2-1:0]       read_burst_start_offset;
    logic [AXI_DATA-1:0]           read_beat_data;
    logic                          read_burst_done_error;
    logic                          read_pause;

    // 接收侧将 AXI beat 压紧后追加到 128B 流缓冲，再按 row_bytes 逐行取出。
    logic [AXI_BEAT_LG2:0]         read_beat_byte_count;
    logic [AXI_DATA-1:0]           read_beat_compact_data;
    logic [AXI_DATA-1:0]           read_beat_valid_data;
    logic [AXI_DATA-1:0]           read_beat_valid_mask;
    logic [ROW_BYTE_W-1:0]         read_beat_pad_bytes;
    logic [AXI_DATA*2-1:0]         recv_stream_data;
    logic [STREAM_COUNT_W-1:0]     recv_stream_byte_count;
    logic [STREAM_COUNT_W-1:0]     recv_stream_count_after_pop;
    logic [STREAM_COUNT_W:0]       recv_stream_count_next;
    logic [AXI_DATA*2-1:0]         recv_stream_data_after_pop;
    logic [AXI_DATA*2-1:0]         recv_stream_data_next;
    logic [ROW_BYTE_W-1:0]         recv_consume_bytes;
    logic                          recv_stream_row_ready;
    logic [AXI_DATA-1:0]           recv_row_data_mask;
    logic [ROW_BYTE_W-1:0]         recv_row_pad_bytes;
    logic                          ab_wr_fire;

    logic                          recv_row_done;
    logic                          recv_last_row;
    logic                          recv_cmd_error;

    logic                          recv_cmd_success_done;
    logic                          recv_cmd_fault_done;

    logic                          m_axi_arlock_unused;
    logic [3:0]                    m_axi_arcache_unused;
    logic [2:0]                    m_axi_arprot_unused;
    logic [3:0]                    m_axi_arqos_unused;
    logic [0:0]                    m_axi_aruser_unused;
    logic [0:0]                    m_axi_ruser_tied;

// =========================================================================
// 0) 命令接收路径
// =========================================================================

    // 先缓存完整矩阵 load 命令；一条命令可连续发出多个 row burst。
    assign mem_ready_o = !issue_cmd_fifo_full && !pc_fifo_full;
    assign issue_cmd_push = mem_valid_i && mem_ready_o;
    assign mem_row_byte_num = mem_cols_i[6:0] << mem_elem_bytes_i;
    assign issue_cmd_fifo_data_in =
        {mem_reg_i, mem_ab_scale_sel_i, mem_row_byte_num, mem_base_i, mem_stride_i, mem_rows_i};

    // PC 只按整条命令保存；完成沿锁存当前队头，同时弹出。
    assign pc_fifo_pop = recv_cmd_success_done || recv_cmd_fault_done;
    fifo #(
        .DATA_WIDTH ( 32             ),
        .DEPTH      ( PC_QUEUE_DEPTH )
    ) u_load_pc_fifo (
        .clk       ( clk              ),
        .rst_n     ( rst_n            ),
        .wr_en_i   ( issue_cmd_push   ),
        .wr_data_i ( mem_pc_i         ),
        .full_o    ( pc_fifo_full     ),
        .rd_en_i   ( pc_fifo_pop      ),
        .rd_data_o ( pc_fifo_data_out ),
        .empty_o   ()
    );

    fifo #(
        .DATA_WIDTH ( CMD_DATA        ),
        .DEPTH      ( CMD_QUEUE_DEPTH )
    ) u_issue_cmd_fifo (
        .clk       ( clk                    ),
        .rst_n     ( rst_n                  ),
        .wr_en_i   ( issue_cmd_push         ),
        .wr_data_i ( issue_cmd_fifo_data_in ),
        .full_o    ( issue_cmd_fifo_full    ),
        .rd_en_i   ( issue_cmd_pop          ),
        .rd_data_o ( issue_cmd_fifo_rd_data ),
        .empty_o   ( issue_cmd_fifo_empty   )
    );

// =========================================================================
// 1) 命令发射路径
// =========================================================================

    // 前一条命令发完 burst 请求即可切换；返回侧通过描述符和 LOAD 尾拍保序。
    assign issue_cmd_pop =
        !issue_cmd_active &&
        !issue_cmd_fifo_empty &&
        !inflight_fifo_full;

    // 整条 DMA 只有在内存行连续且单个 AXI burst 不跨4KB边界时才合并。
    assign issue_cmd_fifo_total_bytes =
        {{(DMA_TOTAL_BYTE_W-8){1'b0}}, issue_cmd_fifo_rows} *
        {{(DMA_TOTAL_BYTE_W-ROW_BYTE_W){1'b0}}, issue_cmd_fifo_row_bytes};
    assign issue_cmd_fifo_4k_bytes_left =
        13'd4096 - {1'b0, issue_cmd_fifo_base[11:0]};
    assign issue_cmd_fifo_contiguous =
        issue_cmd_fifo_stride ==
        {{(32-ROW_BYTE_W){1'b0}}, issue_cmd_fifo_row_bytes};

    // 乘法、4KB减法和 stride 比较的结果均已寄存，合并判定只剩简单比较。
    assign issue_cmd_merge_rows =
        (issue_cmd_rows != '0) &&
        (issue_cmd_row_bytes != '0) &&
        issue_cmd_contiguous &&
        (issue_cmd_total_bytes <= issue_cmd_4k_bytes_left);

    // 连续布局命令只发一个合并 burst；非连续布局保持每行一个 burst。
    assign issue_has_request = issue_cmd_merge_rows ?
                               (bursts_issued == '0) :
                               (bursts_issued < issue_cmd_rows);

    assign issue_request_last = issue_cmd_merge_rows ||
                                (issue_row_last && ((bursts_issued + 1'b1) == issue_cmd_rows));

    // valid 只表示当前存在待发送请求，不依赖下层 ready。
    // ready 拉低时，issue_addr 和 cmd_burst_byte_num 保持不变。
    assign read_burst_valid =
        issue_cmd_active &&
        issue_has_request;

    // 下层真正接收一次 burst 请求后，才推进发射侧状态。
    assign read_burst_fire = read_burst_valid && !read_req_busy;

    // 指令发射结束
    assign issue_cmd_done =
        issue_cmd_active &&
        read_burst_fire &&
        issue_request_last;

    // 指令正在发射
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_cmd_active <= 1'b0;
        end else begin
            if (issue_cmd_pop) begin
                issue_cmd_active <= 1'b1;
            end else if (issue_cmd_done) begin
                issue_cmd_active <= 1'b0;
            end
        end
    end

    assign {issue_cmd_fifo_reg, issue_cmd_fifo_dst_sel,
            issue_cmd_fifo_row_bytes, issue_cmd_fifo_base,
            issue_cmd_fifo_stride, issue_cmd_fifo_rows} = issue_cmd_fifo_rd_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_cmd_row_bytes <= '0;
            issue_cmd_stride <= '0;
            issue_cmd_rows <= '0;
            issue_cmd_total_bytes <= '0;
            issue_cmd_4k_bytes_left <= '0;
            issue_cmd_contiguous <= 1'b0;
        end else begin
            if (issue_cmd_pop) begin
                issue_cmd_row_bytes <= issue_cmd_fifo_row_bytes;
                issue_cmd_stride <= issue_cmd_fifo_stride;
                issue_cmd_rows <= issue_cmd_fifo_rows;
                issue_cmd_total_bytes <= issue_cmd_fifo_total_bytes;
                issue_cmd_4k_bytes_left <= issue_cmd_fifo_4k_bytes_left;
                issue_cmd_contiguous <= issue_cmd_fifo_contiguous;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bursts_issued <= '0;
        end else begin
            if (issue_cmd_pop) begin
                bursts_issued <= '0;
            end else if (read_burst_fire && issue_row_last) begin
                bursts_issued <= bursts_issued + 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_addr <= '0;
        end else begin
            if (issue_cmd_pop) begin
                issue_addr <= issue_cmd_fifo_base;
            end else if (read_burst_fire && !issue_cmd_merge_rows) begin
                issue_addr <= issue_row_last ?
                    issue_addr - issue_row_offset + issue_cmd_stride :
                    issue_addr + cmd_burst_byte_num;
            end
        end
    end

    // 连续布局使用整条 DMA 的总字节数；否则仍请求单行字节数。
    assign issue_page_left = 13'd4096 - {1'b0, issue_addr[11:0]};
    assign cmd_burst_byte_num = issue_cmd_merge_rows ?
        issue_cmd_total_bytes[BURST_BYTE_W-1:0] :
        ((issue_cmd_row_bytes - issue_row_offset) > issue_page_left ?
         issue_page_left : (issue_cmd_row_bytes - issue_row_offset));
    assign issue_row_last = issue_cmd_merge_rows ||
        (issue_row_offset + cmd_burst_byte_num == issue_cmd_row_bytes);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            issue_row_offset <= '0;
        else if (issue_cmd_pop)
            issue_row_offset <= '0;
        else if (read_burst_fire)
            issue_row_offset <= issue_row_last ? '0 :
                                issue_row_offset + cmd_burst_byte_num;
    end

    // -------------------------------------------------------------------------
    // AXI burst 读控制子模块
    // -------------------------------------------------------------------------
    AxiReadBurstCtrl #(
        .AXI_ID_WIDTH         ( AXI_ID                 ),
        .AXI_ADDR_WIDTH       ( AXI_ADDR               ),
        .AXI_DATA_WIDTH       ( AXI_DATA               ),
        .AXI_ARUSER_WIDTH     ( 1                      ),
        .AXI_RUSER_WIDTH      ( 1                      ),
        .READ_OUTSTANDING_DEPTH ( READ_OUTSTANDING_DEPTH  ),
        .BURST_BYTE_NUM_WIDTH ( BURST_BYTE_W           )
    ) u_axi_read_burst_ctrl (
        .clk                 ( clk                    ),
        .rst_n               ( rst_n                  ),
        .burst_addr_i        ( issue_addr             ),
        .burst_byte_num_i    ( cmd_burst_byte_num     ),
        .burst_valid_i       ( read_burst_valid       ),
        .burst_cmd_last_i    ( issue_request_last     ),
        .r_pause_i           ( read_pause             ),
        .r_req_busy_o        ( read_req_busy          ),
        .r_burst_busy_o      ( read_busy              ),
        .r_beat_valid_o      ( read_beat_valid        ),
        .r_beat_first_o      ( read_beat_first        ),
        .r_beat_last_o       ( read_beat_last         ),
        .r_cmd_last_o        ( read_cmd_last          ),
        .r_burst_start_offset_o ( read_burst_start_offset ),
        .r_beat_byte_count_o ( read_beat_byte_count   ),
        .r_beat_data_o       ( read_beat_data         ),
        .r_burst_done_error_o( read_burst_done_error  ),
        .M_AXI_ARID          ( m_axi_arid_o           ),
        .M_AXI_ARADDR        ( m_axi_araddr_o         ),
        .M_AXI_ARLEN         ( m_axi_arlen_o          ),
        .M_AXI_ARSIZE        ( m_axi_arsize_o         ),
        .M_AXI_ARBURST       ( m_axi_arburst_o        ),
        .M_AXI_ARLOCK        ( m_axi_arlock_unused    ),
        .M_AXI_ARCACHE       ( m_axi_arcache_unused   ),
        .M_AXI_ARPROT        ( m_axi_arprot_unused    ),
        .M_AXI_ARQOS         ( m_axi_arqos_unused     ),
        .M_AXI_ARUSER        ( m_axi_aruser_unused    ),
        .M_AXI_ARVALID       ( m_axi_arvalid_o        ),
        .M_AXI_ARREADY       ( m_axi_arready_i        ),
        .M_AXI_RID           ( m_axi_rid_i            ),
        .M_AXI_RDATA         ( m_axi_rdata_i          ),
        .M_AXI_RRESP         ( m_axi_rresp_i          ),
        .M_AXI_RLAST         ( m_axi_rlast_i          ),
        .M_AXI_RUSER         ( m_axi_ruser_tied       ),
        .M_AXI_RVALID        ( m_axi_rvalid_i         ),
        .M_AXI_RREADY        ( m_axi_rready_o         )
    );

    assign m_axi_ruser_tied = '0;

    // AXI 控制器将 R 握手数据寄存一拍后返回。本拍更新缓冲后，必须仍为
    // 下一拍可能返回的完整 beat 预留空间；小于一拍的行尾消费尤其需要此保护。
    // read_cmd_last 与寄存后的尾拍同时到达，立即挡住下一条 LOAD 的 R 握手。
    // data_done 将暂停保持到旧缓冲写完、下一条描述符装入，避免跨命令拼接。
    assign read_pause = inflight_cmd_pop || read_cmd_last || recv_cmd_data_done ||
        (recv_stream_count_next > (STREAM_BUFFER_BYTES - AXI_STRB));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            recv_cmd_data_done <= 1'b0;
        else if (inflight_cmd_pop)
            recv_cmd_data_done <= 1'b0;
        else if (read_cmd_last)
            recv_cmd_data_done <= 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recv_cmd_active <= 1'b0;
        end else begin
            if (inflight_cmd_pop) begin
                recv_cmd_active <= 1'b1;
            end else if (recv_cmd_success_done || recv_cmd_fault_done) begin
                recv_cmd_active <= 1'b0;
            end
        end
    end

    assign inflight_cmd_pop =
        !recv_cmd_active &&
        !inflight_fifo_empty;

    // 命令一开始发 AR 就进入 in-flight FIFO。R 通道使用单 ID 保序返回，
    // 因此接收侧按 FIFO 顺序恢复每条大命令的上下文即可。
    assign inflight_fifo_data_in = {
        issue_cmd_fifo_reg,
        issue_cmd_fifo_dst_sel,
        issue_cmd_fifo_row_bytes,
        issue_cmd_fifo_rows
    };

    fifo #(
        .DATA_WIDTH ( INFLIGHT_DATA   ),
        .DEPTH      ( CMD_QUEUE_DEPTH )
    ) u_inflight_cmd_fifo (
        .clk       ( clk                    ),
        .rst_n     ( rst_n                  ),
        .wr_en_i   ( issue_cmd_pop          ),
        .wr_data_i ( inflight_fifo_data_in  ),
        .full_o    ( inflight_fifo_full     ),
        .rd_en_i   ( inflight_cmd_pop       ),
        .rd_data_o ( inflight_fifo_rd_data  ),
        .empty_o   ( inflight_fifo_empty    )
    );

    assign {inflight_fifo_reg, inflight_fifo_dst_sel,
            inflight_fifo_row_bytes, inflight_fifo_rows} = inflight_fifo_rd_data;

    assign recv_cmd_reg_idx = recv_cmd_reg[1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recv_cmd_reg <= '0;
            recv_cmd_dst_sel <= 1'b0;
            recv_cmd_row_bytes <= '0;
            recv_cmd_rows <= '0;
        end else begin
            if (inflight_cmd_pop) begin
                recv_cmd_reg <= inflight_fifo_reg;
                recv_cmd_dst_sel <= inflight_fifo_dst_sel;
                recv_cmd_row_bytes <= inflight_fifo_row_bytes;
                recv_cmd_rows <= inflight_fifo_rows;
            end
        end
    end

    // =========================================================================
    // 2) receive / ABMatrixReg write 路
    // =========================================================================
    // AXI 整命令读过程是否出现错误。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recv_cmd_fault_seen <= 1'b0;
        end else if (inflight_cmd_pop) begin
            recv_cmd_fault_seen <= 1'b0;
        end else if (read_burst_done_error) begin
            recv_cmd_fault_seen <= 1'b1;
        end
    end

    assign recv_chunk_last = (recv_row_offset + recv_chunk_bytes == recv_cmd_row_bytes);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            recv_row_offset <= '0;
        else if (inflight_cmd_pop)
            recv_row_offset <= '0;
        else if (ab_wr_fire)
            recv_row_offset <= recv_chunk_last ? '0 : recv_row_offset + recv_chunk_bytes;
    end

    // 写口固定为 64B。每次取行内一个 segment，末段不足 64B 时高字节补零。
    assign recv_chunk_bytes = (recv_cmd_row_bytes - recv_row_offset > AXI_STRB) ?
                              AXI_STRB : recv_cmd_row_bytes - recv_row_offset;

    assign recv_consume_bytes = ab_wr_fire ? recv_chunk_bytes : '0;
    // 计算流缓冲中剩余有效字节数。每次写出后减去已消费字节数。
    assign recv_stream_count_after_pop = recv_stream_byte_count - recv_consume_bytes;
    assign recv_stream_count_next = {1'b0, recv_stream_count_after_pop} +
        ((recv_cmd_active && read_beat_valid && !recv_cmd_error) ? read_beat_byte_count : '0);

    // 计算缓存中有效字节数。每次写出后减去已消费字节数，每次接收新 beat 后加上有效字节数。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recv_stream_byte_count <= '0;
        end else if (inflight_cmd_pop || read_burst_done_error) begin
            recv_stream_byte_count <= '0;
        end else if (ab_wr_fire || (recv_cmd_active && read_beat_valid && !recv_cmd_error)) begin
            recv_stream_byte_count <= recv_stream_count_next[STREAM_COUNT_W-1:0];
        end
    end

    // burst 首拍先移除地址低位产生的无效 byte lane，后续拍本身从 lane0 有效。
    assign read_beat_compact_data = read_beat_first ?
        (read_beat_data >> {read_burst_start_offset, 3'b000}) : read_beat_data;

    // byte_count 之外的数据属于 AXI beat 中的无效区域，追加前用低位连续掩码清零。
    assign read_beat_pad_bytes = AXI_STRB - read_beat_byte_count;
    assign read_beat_valid_mask = {AXI_DATA{1'b1}} >> {read_beat_pad_bytes, 3'b000};
    assign read_beat_valid_data = read_beat_compact_data & read_beat_valid_mask;

    // 仅有效返回才能追加；只写 SRAM 时不能把上一拍残留数据重新 OR 入缓冲。
    assign recv_stream_data_after_pop = recv_stream_data >> {recv_consume_bytes, 3'b000};
    assign recv_stream_data_next = recv_stream_data_after_pop |
        ((recv_cmd_active && read_beat_valid && !recv_cmd_error) ?
         ({{AXI_DATA{1'b0}}, read_beat_valid_data} << {recv_stream_count_after_pop, 3'b000}) :
         {AXI_DATA*2{1'b0}});

    // 同时存在写出和新 beat 时，先移除低位已消费数据，再把新 beat 追加到剩余数据之后。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recv_stream_data <= '0;
        end else if (inflight_cmd_pop || read_burst_done_error) begin
            recv_stream_data <= '0;
        end else if (ab_wr_fire || (recv_cmd_active && read_beat_valid && !recv_cmd_error)) begin
            recv_stream_data <= recv_stream_data_next;
        end
    end

    assign recv_stream_row_ready =
        recv_cmd_active &&
        (recv_cmd_row_bytes != '0) &&
        (recv_stream_byte_count >= recv_chunk_bytes);

    assign ab_wr_fire  = recv_stream_row_ready && !recv_cmd_error;
    assign ab_wr_en_o  = ab_wr_fire && !recv_cmd_reg[2];
    assign c_wr_en_o = ab_wr_fire && recv_cmd_reg[2];
    assign c_wr_half_o = recv_row_offset[6];
    assign c_wr_nblock_o = recv_row_offset[7];
    assign ab_wr_reg_o = recv_cmd_reg_idx;
    assign ab_wr_dst_sel_o = recv_cmd_dst_sel;

    assign recv_row_pad_bytes = AXI_STRB - recv_chunk_bytes;
    assign recv_row_data_mask = {AXI_DATA{1'b1}} >> {recv_row_pad_bytes, 3'b000};
    assign ab_wr_data_o = recv_stream_data[AXI_DATA-1:0] & recv_row_data_mask;

    // 行内最后一个 segment 写入后才推进逻辑行号。
    assign recv_row_done = ab_wr_fire && recv_chunk_last;
    // AB Martix Reg 写口的行号输出
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rows_received <= '0;
        end else begin
            if (inflight_cmd_pop) begin
                rows_received <= '0;
            end else if (recv_row_done) begin
                rows_received <= rows_received + 1'b1;
            end
        end
    end
    assign ab_wr_row_o  = rows_received[5:0];

    assign recv_last_row = ((rows_received + 1'b1) == recv_cmd_rows);
    assign recv_cmd_error = recv_cmd_fault_seen || read_burst_done_error;

    assign recv_cmd_success_done = recv_cmd_active && recv_last_row &&
                                   recv_row_done && !recv_cmd_error &&
                                   (recv_cmd_data_done || read_cmd_last);

    assign recv_cmd_fault_done = recv_cmd_active && recv_cmd_error &&
                                 recv_cmd_data_done && !read_beat_valid;

    // =========================================================================
    // 4) 完成 / busy 汇报
    // =========================================================================
    assign busy_o =
        issue_cmd_active ||
        recv_cmd_active ||
        !issue_cmd_fifo_empty ||
        !inflight_fifo_empty ||
        issue_cmd_push ||
        issue_cmd_pop ||
        read_busy ||
        (recv_stream_byte_count != '0) ||
        read_burst_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_valid_o <= 1'b0;
            done_fault_o <= 1'b0;
            done_pc_o <= '0;
            done_fault_addr_o <= '0;
        end else begin
            done_valid_o <= 1'b0;
            done_fault_o <= 1'b0;

            if (recv_cmd_success_done) begin
                done_valid_o <= 1'b1;
                done_pc_o <= pc_fifo_data_out;
            end else if (recv_cmd_fault_done) begin
                done_valid_o <= 1'b1;
                done_fault_o <= 1'b1;
                done_pc_o <= pc_fifo_data_out;
                // 接收侧不再携带请求地址 metadata，当前无法精确回报故障地址。
                done_fault_addr_o <= '0;
            end
        end
    end

endmodule
