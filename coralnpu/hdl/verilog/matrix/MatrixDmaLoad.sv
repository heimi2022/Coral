/*
矩阵 load 子模块

这一版按“矩阵寄存器 backend 由多个 256b SRAM bank 组成”来设计：
1. issue 路：
   - 只要命令还没把所有行都发完
   - 且 AxiReadBurstCtrl 还能接新 burst
   就继续发下一行请求，不再等前一行收完
2. receive / direct-write 路：
   - AXI R 通道按单 ID、按序返回
   - 如果当前行起始地址 256b 对齐，则每个 AXI beat 直接写一个 matrix bank
   - 如果当前行起始地址不对齐，则用“上一拍 raw beat + 当前拍 raw beat”拼成一个对齐的 256b bank 写

说明：
1. 当前仍然保持“同一时刻只执行一条矩阵 load 大命令”，但命令内部的多行可并行在途
2. 当前使用单 AXI ID，不支持乱序返回；依赖 AXI 对同 ID 返回顺序的保证
3. 当前 fault 语义偏硬件直写风格：
   - 检测到 burst error 后停止继续发新请求
   - 已经直写进矩阵寄存器的 beat 不回滚
*/

module MatrixDmaLoad #(
    parameter int AXI_ADDR = 32,
    parameter int AXI_DATA = 256,
    parameter int AXI_ID   = 1,
    parameter int REG_IDX  = 2,
    parameter int REG_BEAT = $clog2((4096 + (AXI_DATA / 8) - 1) / (AXI_DATA / 8)),
    parameter int TRAN_BYTE_NUM = 16,
    parameter int CMD_QUEUE_DEPTH = 3,
    parameter int READ_OUTSTANDING_DEPTH = 4
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // ------------------------------------------------------------------------
    // 归一化后的矩阵 load 命令输入。
    // 语义：
    // 1. mem_rows_i 表示本条命令需要发多少次 burst
    // 2. mem_cols_i * elem_bytes 表示单次 burst 的有效字节数
    // 3. 第 i 次 burst 的地址 = base + i * stride
    // ------------------------------------------------------------------------
    input  logic                     mem_valid_i,
    output logic                     mem_ready_o,
    input  logic [31:0]              mem_pc_i,
    input  logic [2:0]               mem_reg_i,
    input  logic                     mem_layout_i,
    input  logic                     mem_whole_i,
    input  logic [1:0]               mem_elem_bytes_i, // 0: 1 byte, 1: 2 bytes, 2: 4 bytes
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
    // 矩阵寄存器 256b bank 写口。
    // 这一版把它看成“一个 bank 一行 = 256b”的直写接口。
    // ------------------------------------------------------------------------
    output logic                     reg_wr_en_o,    // 本拍写矩阵寄存器 bank
    output logic                     reg_wr_kind_o,  // 0=tile, 1=acc
    output logic [REG_IDX-1:0]       reg_wr_idx_o,   // 第几个矩阵寄存器
    output logic [REG_BEAT-1:0]      reg_wr_beat_o,  // 该寄存器内第几个 256b bank
    output logic [AXI_DATA-1:0]      reg_wr_data_o,  // 写入 bank 的 256b 数据
    output logic [AXI_DATA/8-1:0]    reg_wr_strb_o,  // 写入 bank 的字节使能

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
    localparam int CMD_DATA = 119;

    logic [CMD_DATA-1:0]           issue_cmd_fifo_data_in;
    logic [CMD_DATA-1:0]           issue_cmd_fifo_rd_data;
    logic                          issue_cmd_fifo_full;
    logic                          issue_cmd_fifo_empty;
    logic                          issue_cmd_push;
    logic                          issue_cmd_pop;

    logic [31:0]                   issue_cmd_fifo_pc;
    logic [2:0]                    issue_cmd_fifo_reg;
    logic                          issue_cmd_fifo_layout;
    logic                          issue_cmd_fifo_whole;
    logic [1:0]                    issue_cmd_fifo_elem_bytes;
    logic [31:0]                   issue_cmd_fifo_base;
    logic [31:0]                   issue_cmd_fifo_stride;
    logic [7:0]                    issue_cmd_fifo_rows;
    logic [7:0]                    issue_cmd_fifo_cols;

    logic [CMD_DATA-1:0]         inflight_fifo_rd_data;
    logic                          inflight_fifo_full;
    logic                          inflight_fifo_empty;
    logic                          inflight_cmd_pop;

    logic [31:0]                   inflight_fifo_pc;
    logic [2:0]                    inflight_fifo_reg;
    logic                          inflight_fifo_layout;
    logic                          inflight_fifo_whole;
    logic [1:0]                    inflight_fifo_elem_bytes;
    logic [31:0]                   inflight_fifo_base;
    logic [31:0]                   inflight_fifo_stride;
    logic [7:0]                    inflight_fifo_rows;
    logic [7:0]                    inflight_fifo_cols;

    logic                          issue_cmd_active;
    logic [1:0]                    issue_cmd_elem_bytes;
    logic [31:0]                   issue_cmd_stride;
    logic [7:0]                    issue_cmd_rows;
    logic [7:0]                    issue_cmd_cols;

    logic                          recv_cmd_active;
    logic                          recv_cmd_fault_seen;
    logic [31:0]                   recv_cmd_pc;
    logic [2:0]                    recv_cmd_reg;
    logic                          recv_cmd_layout;
    logic                          recv_cmd_whole;
    logic [1:0]                    recv_cmd_elem_bytes;
    logic [31:0]                   recv_cmd_stride;
    logic [7:0]                    recv_cmd_rows;
    logic [7:0]                    recv_cmd_cols;
    logic [31:0]                   issue_addr;
    logic [31:0]                   recv_addr;
    logic [31:0]                   fault_addr;

    logic [7:0]                    rows_issued;
    logic [7:0]                    rows_received;

    logic                          recv_cmd_reg_kind;
    logic [REG_IDX-1:0]            recv_cmd_reg_idx;
    logic [TRAN_BYTE_NUM-1:0]    cmd_burst_byte_num;

    logic                          start_read;
    logic                          issue_cmd_done;

    logic                          read_req_busy;
    logic                          read_busy;
    logic                          read_beat_valid;
    logic [AXI_STRB-1:0]         read_beat_strb;
    logic [AXI_DATA-1:0]         read_beat_data;
    logic                          read_burst_done;
    logic                          read_burst_done_error;
    logic                          read_pause;

    // 当前正在返回这一行的行内状态。
    logic [REG_BEAT-1:0]           recv_bank_beat_idx;
    logic                          recv_prev_raw_valid;
    logic [AXI_DATA-1:0]           recv_prev_raw_data;
    logic [AXI_STRB-1:0]           recv_prev_raw_strb;
    logic                          recv_tail_pending;
    logic                          recv_row_aligned;
    logic [AXI_BEAT_LG2-1:0]       recv_row_offset;
    logic [AXI_DATA-1:0]           recv_aligned_data;
    logic [AXI_STRB-1:0]           recv_aligned_strb;
    logic [AXI_DATA-1:0]           recv_tail_data;
    logic [AXI_STRB-1:0]           recv_tail_strb;
    logic [AXI_STRB-1:0]           recv_tail_strb_from_read;
    logic                          recv_tail_flush_needed;
    logic                          reg_wr_from_read;
    logic                          reg_wr_fire;
    logic [REG_BEAT-1:0]           reg_wr_base_beat;
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

    function automatic [REG_BEAT-1:0] row_base_beat_from_idx;
        input                          reg_kind;
        input [7:0]                    row_idx;
        reg   [REG_BEAT+1:0]         tmp;
        begin
            if (reg_kind) begin
                tmp = row_idx << 2;
            end else begin
                tmp = row_idx << 1;
            end
            row_base_beat_from_idx = tmp[REG_BEAT-1:0];
        end
    endfunction

    // 非对齐数据拼接函数：将上一拍和当前拍的 raw beat 按照行起始地址的偏移量拼成一个对齐的 beat
    function automatic [AXI_DATA-1:0] align_data_beat;
        input [AXI_DATA-1:0]         prev_data;
        input [AXI_DATA-1:0]         curr_data;
        input [AXI_BEAT_LG2-1:0]     start_offset;  // 偏移字节
        reg   [(AXI_DATA * 2)-1:0]   merged;
        reg   [(AXI_DATA * 2)-1:0]   shifted;
        begin
            merged = {curr_data, prev_data};
            shifted = merged >> (start_offset << 3);
            align_data_beat = shifted[AXI_DATA-1:0];
        end
    endfunction

    function automatic [AXI_STRB-1:0] align_strb_beat;
        input [AXI_STRB-1:0]         prev_strb;
        input [AXI_STRB-1:0]         curr_strb;
        input [AXI_BEAT_LG2-1:0]       start_offset;
        reg   [(AXI_STRB * 2)-1:0]   merged;
        reg   [(AXI_STRB * 2)-1:0]   shifted;
        begin
            merged = {curr_strb, prev_strb};
            shifted = merged >> start_offset;
            align_strb_beat = shifted[AXI_STRB-1:0];
        end
    endfunction

// =========================================================================
// 1) 命令发射路径
// =========================================================================

// issue_cmd_fifo
    assign issue_cmd_push = mem_valid_i && mem_ready_o;
    assign mem_ready_o = !issue_cmd_fifo_full;
    assign issue_cmd_fifo_data_in = {
        mem_pc_i,
        mem_reg_i,
        mem_layout_i,
        mem_whole_i,
        mem_elem_bytes_i,
        mem_base_i,
        mem_stride_i,
        mem_rows_i,
        mem_cols_i 
    };
    
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

    assign issue_cmd_pop =
        !issue_cmd_active &&
        !issue_cmd_fifo_empty &&
        !inflight_fifo_full;

    assign issue_cmd_done =
        issue_cmd_active &&
        start_read &&
        ((rows_issued + 1'b1) == issue_cmd_rows);

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

    assign issue_cmd_fifo_pc         = issue_cmd_fifo_rd_data[118:87];
    assign issue_cmd_fifo_reg        = issue_cmd_fifo_rd_data[86:84];
    assign issue_cmd_fifo_layout     = issue_cmd_fifo_rd_data[83];
    assign issue_cmd_fifo_whole      = issue_cmd_fifo_rd_data[82];
    assign issue_cmd_fifo_elem_bytes = issue_cmd_fifo_rd_data[81:80];
    assign issue_cmd_fifo_base       = issue_cmd_fifo_rd_data[79:48];
    assign issue_cmd_fifo_stride     = issue_cmd_fifo_rd_data[47:16];
    assign issue_cmd_fifo_rows       = issue_cmd_fifo_rd_data[15:8];
    assign issue_cmd_fifo_cols       = issue_cmd_fifo_rd_data[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_cmd_elem_bytes <= '0;
            issue_cmd_stride <= '0;
            issue_cmd_rows <= '0;
            issue_cmd_cols <= '0;
        end else begin
            if (issue_cmd_pop) begin
                issue_cmd_elem_bytes <= issue_cmd_fifo_elem_bytes;
                issue_cmd_stride <= issue_cmd_fifo_stride;
                issue_cmd_rows <= issue_cmd_fifo_rows;
                issue_cmd_cols <= issue_cmd_fifo_cols;
            end
        end
    end

    assign start_read =
        issue_cmd_active &&
        (rows_issued < issue_cmd_rows) &&
        !read_req_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rows_issued <= '0;
        end else begin
            if (issue_cmd_pop) begin
                rows_issued <= '0;
            end else if (start_read) begin
                rows_issued <= rows_issued + 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_addr <= '0;
        end else begin
            if (issue_cmd_pop) begin
                issue_addr <= issue_cmd_fifo_base;
            end else if (start_read) begin
                issue_addr <= issue_addr + issue_cmd_stride;
            end
        end
    end

    // 一行多少 byte
    assign cmd_burst_byte_num = issue_cmd_cols << issue_cmd_elem_bytes;

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
        .BURST_BYTE_NUM_WIDTH ( TRAN_BYTE_NUM          )
    ) u_axi_read_burst_ctrl (
        .clk                 ( clk                    ),
        .rst_n               ( rst_n                  ),
        .burst_addr_i        ( issue_addr             ), 
        .burst_byte_num_i    ( cmd_burst_byte_num     ), 
        .burst_valid_i       ( start_read             ), 
        .r_pause_i           ( read_pause             ), 
        .r_req_busy_o        ( read_req_busy          ), 
        .r_burst_busy_o      ( read_busy              ),
        .r_beat_valid_o      ( read_beat_valid        ),
        .r_beat_strb_o       ( read_beat_strb         ),
        .r_beat_data_o       ( read_beat_data         ),
        .r_burst_done_o      ( read_burst_done        ),
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

    // TODO
    // 非对齐尾拍补写或命令切换边界时，暂停接收新的 R beat。
    assign read_pause =
        recv_tail_pending ||
        inflight_cmd_pop ||
        recv_cmd_success_done ||
        recv_cmd_fault_done;

// inflight_cmd_fifo
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

    fifo #(
        .DATA_WIDTH ( CMD_DATA        ),
        .DEPTH      ( CMD_QUEUE_DEPTH )
    ) u_inflight_cmd_fifo (
        .clk       ( clk                   ),
        .rst_n     ( rst_n                 ),
        .wr_en_i   ( issue_cmd_pop         ),
        .wr_data_i ( issue_cmd_fifo_rd_data ),
        .full_o    ( inflight_fifo_full    ),
        .rd_en_i   ( inflight_cmd_pop      ),
        .rd_data_o ( inflight_fifo_rd_data ),
        .empty_o   ( inflight_fifo_empty   )
    );

    assign inflight_fifo_pc         = inflight_fifo_rd_data[118:87];
    assign inflight_fifo_reg        = inflight_fifo_rd_data[86:84];
    assign inflight_fifo_layout     = inflight_fifo_rd_data[83];
    assign inflight_fifo_whole      = inflight_fifo_rd_data[82];
    assign inflight_fifo_elem_bytes = inflight_fifo_rd_data[81:80];
    assign inflight_fifo_base       = inflight_fifo_rd_data[79:48];
    assign inflight_fifo_stride     = inflight_fifo_rd_data[47:16];
    assign inflight_fifo_rows       = inflight_fifo_rd_data[15:8];
    assign inflight_fifo_cols       = inflight_fifo_rd_data[7:0];

    assign recv_cmd_reg_kind = recv_cmd_reg[2];
    assign recv_cmd_reg_idx  = recv_cmd_reg[1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fault_addr <= '0;
        end else begin
            if (read_burst_done_error && !recv_cmd_fault_seen) begin
                fault_addr <= recv_addr;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recv_cmd_pc <= '0;
            recv_cmd_reg <= '0;
            recv_cmd_layout <= 1'b0;
            recv_cmd_whole <= 1'b0;
            recv_cmd_elem_bytes <= '0;
            recv_cmd_stride <= '0;
            recv_cmd_rows <= '0;
            recv_cmd_cols <= '0;
        end else begin
            if (inflight_cmd_pop) begin
                recv_cmd_pc <= inflight_fifo_pc;
                recv_cmd_reg <= inflight_fifo_reg;
                recv_cmd_layout <= inflight_fifo_layout;
                recv_cmd_whole <= inflight_fifo_whole;
                recv_cmd_elem_bytes <= inflight_fifo_elem_bytes;
                recv_cmd_stride <= inflight_fifo_stride;
                recv_cmd_rows <= inflight_fifo_rows;
                recv_cmd_cols <= inflight_fifo_cols;
            end
        end
    end

    // =========================================================================
    // 2) receive / direct-write 路
    // =========================================================================

    // AXI 整命令读过程是否出现错误
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recv_cmd_fault_seen <= 1'b0;
        end else if (inflight_cmd_pop) begin
            recv_cmd_fault_seen <= 1'b0;
        end else if (read_burst_done_error) begin
            recv_cmd_fault_seen <= 1'b1;
        end
    end
    
    assign recv_row_done = (read_burst_done && !recv_tail_flush_needed) || recv_tail_pending;

    // 已经收到的行数
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
    assign recv_last_row = ((rows_received + 1'b1) == recv_cmd_rows);
    assign recv_cmd_error = recv_cmd_fault_seen || read_burst_done_error;

    assign recv_cmd_success_done = recv_cmd_active && recv_last_row &&
                                   recv_row_done && !recv_cmd_error;

    assign recv_cmd_fault_done = recv_cmd_active && recv_last_row &&
                                 recv_cmd_error && read_burst_done;

    // 地址是否对齐
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recv_addr <= '0;
        end else begin
            if (inflight_cmd_pop) begin
                recv_addr <= inflight_fifo_base;
            end else if (recv_row_done) begin
                recv_addr <= recv_addr + recv_cmd_stride;
            end
        end
    end
    assign recv_row_aligned = (recv_addr[AXI_BEAT_LG2-1:0] == '0);
    assign recv_row_offset = recv_addr[AXI_BEAT_LG2-1:0];

    // 非对齐拼接时，缓存上一拍 raw beat 的字节使能。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recv_prev_raw_strb <= '0;
        end else begin
            if (read_beat_valid && !recv_row_aligned) begin
                recv_prev_raw_strb <= read_beat_strb;
            end
        end
    end

    // 当前这一行 burst 收尾时，是否还残留一个待补写的 tail bank。
    assign recv_tail_strb_from_read = read_beat_strb >> recv_row_offset;
    assign recv_tail_flush_needed = read_burst_done &&
                                    !read_burst_done_error &&
                                    !recv_row_aligned &&
                                    (recv_tail_strb_from_read != '0);
    
    // 最后一拍是否还残留一个待补写的 tail 
    wire recv_tail_pending_en = read_burst_done || recv_tail_pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recv_tail_pending <= 1'b0;
        end else if (recv_tail_pending_en) begin
            recv_tail_pending <= recv_tail_flush_needed;
        end
    end

    // 非对齐拼接时，缓存上一拍 raw beat 的数据。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recv_prev_raw_data <= '0;
        end 
        else begin
            if (read_beat_valid && !recv_row_aligned) begin
                recv_prev_raw_data <= read_beat_data;
            end
        end
    end

    // 数据输出
    assign recv_tail_data = align_data_beat(recv_prev_raw_data, {AXI_DATA{1'b0}}, recv_row_offset);
    assign recv_aligned_data = align_data_beat(recv_prev_raw_data, read_beat_data, recv_row_offset);
    assign reg_wr_data_o = recv_tail_pending ? recv_tail_data :
                           (recv_row_aligned ? read_beat_data : recv_aligned_data);
    // 掩码输出
    assign recv_tail_strb = recv_prev_raw_strb >> recv_row_offset;
    assign recv_aligned_strb = align_strb_beat(recv_prev_raw_strb, read_beat_strb, recv_row_offset);
    assign reg_wr_strb_o = recv_tail_pending ? recv_tail_strb :
                           (recv_row_aligned ? read_beat_strb : recv_aligned_strb);

    // 输出有效
    // 非对齐拼接时，记录上一拍 raw beat 是否可用于下一拍拼接。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recv_prev_raw_valid <= 1'b0;
        end else begin
            if (inflight_cmd_pop || recv_row_done) begin
                recv_prev_raw_valid <= 1'b0;
            end else if (read_beat_valid && !recv_row_aligned) begin
                recv_prev_raw_valid <= 1'b1;
            end
        end
    end
    assign reg_wr_from_read = recv_cmd_active && read_beat_valid &&
        !recv_cmd_fault_seen && !read_burst_done_error &&
        (recv_row_aligned || recv_prev_raw_valid);

    assign reg_wr_fire = reg_wr_from_read || recv_tail_pending;
    assign reg_wr_en_o = reg_wr_fire;

    // 输出 目标寄存器 地址
    assign reg_wr_kind_o = recv_cmd_reg_kind;
    assign reg_wr_idx_o = recv_cmd_reg_idx;


    assign reg_wr_base_beat = row_base_beat_from_idx(recv_cmd_reg_kind, rows_received);
    assign reg_wr_beat_o = reg_wr_base_beat + recv_bank_beat_idx;

    // TODO : 鸟ai写的啥东西
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recv_bank_beat_idx <= '0;
        end else begin
            if (inflight_cmd_pop) begin
                recv_bank_beat_idx <= '0;
            end else if (recv_row_done) begin
                recv_bank_beat_idx <= '0;
            end else if (reg_wr_fire) begin
                recv_bank_beat_idx <= recv_bank_beat_idx + 1'b1;
            end
        end
    end

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
        recv_tail_pending ||
        start_read;

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
                done_pc_o <= recv_cmd_pc;
            end else if (recv_cmd_fault_done) begin
                done_valid_o <= 1'b1;
                done_fault_o <= 1'b1;
                done_pc_o <= recv_cmd_pc;
                done_fault_addr_o <= fault_addr;
            end
        end
    end

endmodule
