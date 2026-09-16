/* 
    矩阵寄存器到 DDR 的通用 Store 引擎。 
    1. 当前DMA 对矩阵寄存器读出默认 发出请求后会的下一周期 即可返回数据。 否则需要修改反压逻辑
    2. 软件使用上 存储的地址 需要 64B 对齐，否则wstrb 逻辑会有问题

*/
module MatrixDmaStore #(
    parameter int AXI_ADDR_W              = 32,
    parameter int AXI_DATA_W              = 512,
    parameter int AXI_ID_W                = 1,
    parameter int REG_IDX_W               = 2,
    parameter int ROW_IDX_W               = 6,
    parameter int CMD_QUEUE_DEPTH         = 4,
    parameter int WRITE_OUTSTANDING_DEPTH = 4
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         cmd_valid_i,
    output logic                         cmd_ready_o,
    input  logic [31:0]                  cmd_pc_i,
    input  logic [REG_IDX_W-1:0]         cmd_reg_i,
    input  logic [1:0]                   cmd_source_sel_i,
    input  logic [1:0]                   cmd_elem_bytes_i,
    input  logic [AXI_ADDR_W-1:0]        cmd_base_i,
    input  logic [31:0]                  cmd_stride_i,
    input  logic [7:0]                   cmd_rows_i,
    input  logic [7:0]                   cmd_cols_i,

    output logic                         busy_o,
    output logic                         done_valid_o,
    output logic                         done_fault_o,
    output logic [31:0]                  done_pc_o,
    output logic [AXI_ADDR_W-1:0]        done_fault_addr_o,

    output logic                         matrix_rd_en_o,
    output logic [REG_IDX_W-1:0]         matrix_rd_reg_o,
    output logic [ROW_IDX_W-1:0]         matrix_rd_addr_o,
    output logic                         matrix_rd_nblock_o,
    output logic                         matrix_rd_half_o,
    output logic [1:0]                   matrix_rd_source_sel_o,
    input  logic                         matrix_rd_valid_i,
    input  logic [AXI_DATA_W-1:0]        matrix_rd_data_i,
    output logic                         matrix_rd_ready_o,

    output logic                         m_axi_awvalid_o,
    input  logic                         m_axi_awready_i,
    output logic [AXI_ID_W-1:0]          m_axi_awid_o,
    output logic [AXI_ADDR_W-1:0]        m_axi_awaddr_o,
    output logic [7:0]                   m_axi_awlen_o,
    output logic [2:0]                   m_axi_awsize_o,
    output logic [1:0]                   m_axi_awburst_o,

    output logic                         m_axi_wvalid_o,
    input  logic                         m_axi_wready_i,
    output logic [AXI_DATA_W-1:0]        m_axi_wdata_o,
    output logic [AXI_DATA_W/8-1:0]      m_axi_wstrb_o,
    output logic                         m_axi_wlast_o,

    input  logic                         m_axi_bvalid_i,
    output logic                         m_axi_bready_o,
    input  logic [AXI_ID_W-1:0]          m_axi_bid_i,
    input  logic [1:0]                   m_axi_bresp_i
);
    localparam int BYTE_COUNT        = AXI_DATA_W / 8;
    localparam int BYTE_LG2          = $clog2(BYTE_COUNT);
    localparam int PAGE_OFFSET_W     = 12;
    localparam int PAGE_LEN_W        = PAGE_OFFSET_W - BYTE_LG2;
    localparam int ROW_BYTES_W       = 10;
    localparam int DATA_FIFO_DEPTH   = 2;
    // 包含 MatrixDma 中读数据处理模块的一拍缓存；返回接口遵循 ready/valid。
    localparam int READ_CAPACITY     = DATA_FIFO_DEPTH + 1;
    localparam int READ_COUNT_W      = $clog2(READ_CAPACITY + 1);
    localparam int OUT_COUNT_W       = $clog2(WRITE_OUTSTANDING_DEPTH + 1);

    localparam int CMD_DATA_W = REG_IDX_W + 2 + AXI_ADDR_W + 32 + 8 + ROW_BYTES_W + 8;

    // 一个 entry 对应一个不跨 4KB 的 AXI burst。
    localparam int AW_CTX_DATA_W = AXI_ADDR_W + 8 + REG_IDX_W + 2 + ROW_IDX_W + 8 + ROW_BYTES_W + 1;
    localparam int RESP_DATA_W = AXI_ADDR_W + 1;
    localparam int W_CTX_DATA_W = AXI_ADDR_W + 8 + 8 + ROW_BYTES_W + 1;

    logic [CMD_DATA_W-1:0]      cmd_fifo_data_in;
    logic [CMD_DATA_W-1:0]      cmd_fifo_data_out;
    logic                       cmd_fifo_full;
    logic                       cmd_fifo_empty;
    logic                       cmd_fifo_push;
    logic                       cmd_fifo_pop;
    logic [31:0]                pc_fifo_data_out;
    logic                       pc_fifo_full;
    logic                       pc_fifo_empty;
    logic [REG_IDX_W-1:0]       cmd_fifo_reg;
    logic [1:0]                 cmd_fifo_source_sel;
    logic [AXI_ADDR_W-1:0]      cmd_fifo_base;
    logic [31:0]                cmd_fifo_stride;
    logic [7:0]                 cmd_fifo_rows;
    logic [ROW_BYTES_W-1:0]     cmd_fifo_row_bytes;
    logic [7:0]                 cmd_fifo_len;
    logic [ROW_BYTES_W-1:0]     cmd_row_bytes_calc;
    logic [7:0]                 cmd_len_calc;

    logic                       gen_active_q;
    logic [REG_IDX_W-1:0]       gen_reg_q;
    logic [1:0]                 gen_source_sel_q;
    logic [AXI_ADDR_W-1:0]      gen_addr_q;
    logic [31:0]                gen_stride_q;
    logic [7:0]                 gen_rows_q;
    logic [7:0]                 gen_row_len_q;
    logic [ROW_BYTES_W-1:0]         gen_row_bytes_q;
    logic [ROW_IDX_W-1:0]       gen_row_q;
    logic [ROW_IDX_W:0]         gen_row_p1;
    logic [7:0]                 gen_segment_offset_q;
    logic [8:0]                 gen_segment_offset_next;
    logic [PAGE_LEN_W-1:0]      gen_page_len;
    logic [7:0]                 gen_remaining_len;
    logic [7:0]                 gen_segment_len;
    logic                       gen_segment_last;
    logic                       gen_command_last;
    logic [AXI_ADDR_W-1:0]      gen_segment_addr;

    // AW 已握手的 burst 上下文。W 只能按照该 FIFO 的顺序发送数据。
    logic [AW_CTX_DATA_W-1:0]   aw_ctx_data_in;
    logic [AW_CTX_DATA_W-1:0]   aw_ctx_data_out;
    logic                       aw_ctx_full;
    logic                       aw_ctx_empty;
    logic                       aw_ctx_pop;
    logic [AXI_ADDR_W-1:0]      aw_ctx_addr;
    logic [7:0]                 aw_ctx_len;
    logic [REG_IDX_W-1:0]       aw_ctx_reg;
    logic [1:0]                 aw_ctx_source_sel;
    logic [ROW_IDX_W-1:0]       aw_ctx_matrix_row;
    logic [7:0]                 aw_ctx_beat_offset;
    logic [ROW_BYTES_W-1:0]     aw_ctx_row_bytes;
    logic                       aw_ctx_command_last;

    logic [OUT_COUNT_W-1:0]     axi_outstanding_q;
    logic                       aw_handshake;
    logic                       b_handshake;
    logic                       aw_can_issue;

    logic                       w_active_q;
    logic [AXI_ADDR_W-1:0]      w_addr_q;
    logic [7:0]                 w_len_q;
    logic [7:0]                 w_beat_offset_q;
    logic [ROW_BYTES_W-1:0]     w_row_bytes_q;
    logic                       w_command_last_q;

    logic [AXI_ADDR_W-1:0]      w_addr;
    logic [7:0]                 w_len;
    logic [7:0]                 w_beat_offset;
    logic [ROW_BYTES_W-1:0]     w_row_bytes;
    logic                       w_command_last;

    logic [7:0]                 w_beat_q;
    logic [8:0]                 w_global_beat;
    logic                       w_last;
    logic [AXI_DATA_W/8-1:0]    w_strb;
    logic                       w_burst_done;
    integer                     strb_idx;

    logic [W_CTX_DATA_W-1:0]    w_ctx_data_in, w_ctx_data_out;
    logic                       w_ctx_full, w_ctx_empty, w_ctx_pop;
    logic                       read_active_q, read_burst_done;
    logic [REG_IDX_W-1:0]       read_reg_q;
    logic [ROW_IDX_W-1:0]       read_row_q;
    logic [1:0]                 read_source_sel_q;

    // 只有深度 2 的 beat FIFO，不再缓存整行矩阵数据。
    logic [AXI_DATA_W-1:0]          data_fifo_data_out;
    logic                           data_fifo_empty;
    logic                           data_fifo_full;
    logic                           data_fifo_push;
    logic                           w_handshake;

    logic [READ_COUNT_W-1:0]        read_reserved_q;
    logic [7:0]                     read_issue_beat_q;
    logic [8:0]                     read_last_beat_q;

    logic [RESP_DATA_W-1:0]         resp_fifo_data_in;
    logic [RESP_DATA_W-1:0]         resp_fifo_data_out;
    logic                           resp_fifo_full;
    logic                           resp_fifo_empty;
    logic                           resp_fifo_push;
    logic                           resp_fifo_pop;
    logic [AXI_ADDR_W-1:0]          resp_fifo_addr;
    logic                           resp_fifo_command_last;
    logic                           done_fault_q;
    logic [AXI_ADDR_W-1:0]          done_fault_addr_q;

    integer idx;

    // len 统一表示 beat 数减一，0 表示 1 beat；上游保证列数合法且非零。
    assign cmd_row_bytes_calc = {2'b0, cmd_cols_i} << cmd_elem_bytes_i;
    assign cmd_len_calc = (cmd_row_bytes_calc - 1'b1) >> BYTE_LG2;

    assign cmd_fifo_data_in = { cmd_reg_i,cmd_source_sel_i,cmd_base_i,cmd_stride_i,
                                cmd_rows_i,cmd_row_bytes_calc,cmd_len_calc};
    assign cmd_ready_o   = !cmd_fifo_full && !pc_fifo_full;
    assign cmd_fifo_push = cmd_valid_i && cmd_ready_o;
    assign cmd_fifo_pop  = !gen_active_q && !cmd_fifo_empty;

    fifo #(
        .DATA_WIDTH (CMD_DATA_W),
        .DEPTH      (CMD_QUEUE_DEPTH)
    ) u_store_cmd_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en_i    (cmd_fifo_push),
        .wr_data_i  (cmd_fifo_data_in),
        .full_o     (cmd_fifo_full),
        .rd_en_i    (cmd_fifo_pop),
        .rd_data_o  (cmd_fifo_data_out),
        .empty_o    (cmd_fifo_empty)
    );

    assign { cmd_fifo_reg, cmd_fifo_source_sel, cmd_fifo_base,
        cmd_fifo_stride, cmd_fifo_rows, cmd_fifo_row_bytes, cmd_fifo_len } = cmd_fifo_data_out;

    // 命令参数寄存器。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gen_reg_q        <= '0;
            gen_source_sel_q <= '0;
            gen_stride_q     <= '0;
            gen_row_len_q    <= '0;
            gen_row_bytes_q  <= '0;
            gen_rows_q       <= '0;
        end else if (cmd_fifo_pop) begin
            gen_reg_q        <= cmd_fifo_reg;
            gen_source_sel_q <= cmd_fifo_source_sel;
            gen_stride_q     <= cmd_fifo_stride;
            gen_row_len_q    <= cmd_fifo_len;
            gen_row_bytes_q  <= cmd_fifo_row_bytes;
            gen_rows_q       <= cmd_fifo_rows;
        end
    end

    // 最后一个 AW 握手后，当前命令的地址生成结束。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gen_active_q <= 1'b0;
        end else if (cmd_fifo_pop) begin
            gen_active_q <= 1'b1;
        end else if (aw_handshake && gen_command_last) begin
            gen_active_q <= 1'b0;
        end
    end

    // AW 握手后推进当前行；背压期间保持行号和地址描述不变。
    assign gen_row_p1 = {1'b0, gen_row_q} + 1'b1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gen_row_q            <= '0;
        end else if (aw_handshake) begin
            if (gen_segment_last) begin
                if (gen_row_p1 == gen_rows_q)
                    gen_row_q <= '0;
                else
                    gen_row_q <= gen_row_p1[ROW_IDX_W-1:0];
            end
        end
    end

    assign gen_segment_last = gen_segment_len == gen_remaining_len;

    assign gen_remaining_len = gen_row_len_q - gen_segment_offset_q;
    // 地址按 beat 对齐，页面剩余长度减一等于页内 beat 偏移逐位取反。
    assign gen_page_len = ~gen_segment_addr[PAGE_OFFSET_W-1:BYTE_LG2];
    assign gen_segment_len = (gen_remaining_len > gen_page_len)?  8'(gen_page_len) : gen_remaining_len;
    // offset 是实际 beat 偏移，推进时才将 len 转回 beat 数；保留进位。
    assign gen_segment_offset_next = {1'b0, gen_segment_offset_q} +
                                     {1'b0, gen_segment_len} + 9'd1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gen_segment_offset_q <= '0;
        end else if (aw_handshake) begin
            if (gen_segment_last)
                gen_segment_offset_q <= '0;
            else
                gen_segment_offset_q <= gen_segment_offset_next[7:0];
        end
    end

    // 当前矩阵行在 DDR 中的起始地址。命令开始时加载基地址；完成一行后按 stride 移动到下一行。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gen_addr_q <= '0;
        end else if (cmd_fifo_pop) begin
            gen_addr_q <= cmd_fifo_base;
        end else if (aw_handshake && gen_segment_last && (gen_row_p1 != gen_rows_q)) begin
            gen_addr_q <= gen_addr_q + gen_stride_q;
        end
    end

    //当前 burst 的起始地址
    assign gen_segment_addr = gen_addr_q + (AXI_ADDR_W'(gen_segment_offset_q) << BYTE_LG2);
    assign gen_command_last = gen_segment_last && (gen_row_p1 == gen_rows_q);
    assign aw_ctx_data_in = {gen_segment_addr, gen_segment_len, gen_reg_q, gen_source_sel_q,
        gen_row_q, gen_segment_offset_q, gen_row_bytes_q, gen_command_last };

    assign aw_can_issue    = gen_active_q && (axi_outstanding_q < WRITE_OUTSTANDING_DEPTH);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_outstanding_q <= '0;
        end else begin
            case ({aw_handshake, b_handshake})
                2'b10: axi_outstanding_q <= axi_outstanding_q + 1'b1;
                2'b01: axi_outstanding_q <= axi_outstanding_q - 1'b1;
                default: axi_outstanding_q <= axi_outstanding_q;
            endcase
        end
    end

    /********************** AW 通道 **************************/
    assign m_axi_awvalid_o = aw_can_issue;
    assign m_axi_awid_o    = '0;
    assign m_axi_awaddr_o  = gen_segment_addr;
    assign m_axi_awlen_o   = gen_segment_len;
    assign m_axi_awsize_o  = BYTE_LG2[2:0];
    assign m_axi_awburst_o = 2'b01;

    assign aw_handshake    = m_axi_awvalid_o && m_axi_awready_i;

    fifo #(
        .DATA_WIDTH (AW_CTX_DATA_W),
        .DEPTH      (WRITE_OUTSTANDING_DEPTH)
    ) u_store_aw_context_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en_i    (aw_handshake),
        .wr_data_i  (aw_ctx_data_in),
        .full_o     (aw_ctx_full),
        .rd_en_i    (aw_ctx_pop),
        .rd_data_o  (aw_ctx_data_out),
        .empty_o    (aw_ctx_empty)
    );
    assign { aw_ctx_addr, aw_ctx_len, aw_ctx_reg, aw_ctx_source_sel, aw_ctx_matrix_row,
        aw_ctx_beat_offset, aw_ctx_row_bytes, aw_ctx_command_last} = aw_ctx_data_out;

    // 最后一个读请求发出时即可接续下一段，不等待当前段 WLAST。
    assign aw_ctx_pop = (!read_active_q || read_burst_done) &&!aw_ctx_empty && !w_ctx_full;

    // 全局 beat 地址只在请求侧维护，切换时保存新段的寄存器及行信息。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_reg_q        <= '0;
            read_row_q        <= '0;
            read_source_sel_q <= '0;
            read_last_beat_q  <= '0;
        end else if (aw_ctx_pop) begin
            read_reg_q        <= aw_ctx_reg;
            read_row_q        <= aw_ctx_matrix_row;
            read_source_sel_q <= aw_ctx_source_sel;
            read_last_beat_q  <= {1'b0, aw_ctx_beat_offset} + {1'b0, aw_ctx_len};
        end
    end

    assign read_burst_done = matrix_rd_en_o && ({1'b0, read_issue_beat_q} == read_last_beat_q);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_issue_beat_q <= '0;
        end else if (aw_ctx_pop) begin
            read_issue_beat_q <= aw_ctx_beat_offset;
        end else if (matrix_rd_en_o && !read_burst_done) begin
            read_issue_beat_q <= read_issue_beat_q + 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_active_q <= 1'b0;
        end else if (aw_ctx_pop) begin
            read_active_q <= 1'b1;
        end else if (read_burst_done) begin
            read_active_q <= 1'b0;
        end
    end

    // 已发出矩阵读请求、但还没有被 AXI W 接收的数据数量，用作反压 
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_reserved_q <= '0;
        end else begin
            case ({matrix_rd_en_o, w_handshake})
                2'b10: read_reserved_q <= read_reserved_q + 1'b1;
                2'b01: read_reserved_q <= read_reserved_q - 1'b1;
                default: ;
            endcase
        end
    end

    /************** sram 数据读出 ****************/
    assign matrix_rd_en_o = read_active_q && ((read_reserved_q < READ_CAPACITY) || w_handshake);
    assign matrix_rd_reg_o = read_reg_q;
    assign matrix_rd_addr_o = read_row_q;
    assign matrix_rd_nblock_o = read_issue_beat_q[1];
    assign matrix_rd_half_o = read_issue_beat_q[0];
    assign matrix_rd_source_sel_o = read_source_sel_q;

    // 输入已经过外部处理和暂存，握手后直接进入数据 FIFO。
    assign matrix_rd_ready_o = !data_fifo_full;
    assign data_fifo_push = matrix_rd_valid_i && matrix_rd_ready_o;
    // 存储 W 通道待发送的数据
    fifo #(
        .DATA_WIDTH (AXI_DATA_W),
        .DEPTH      (DATA_FIFO_DEPTH)
    ) u_store_data_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en_i    (data_fifo_push),
        .wr_data_i  (matrix_rd_data_i),
        .full_o     (data_fifo_full),
        .rd_en_i    (w_handshake),
        .rd_data_o  (data_fifo_data_out),
        .empty_o    (data_fifo_empty)
    );

    assign w_ctx_data_in = {aw_ctx_addr, aw_ctx_len, aw_ctx_beat_offset,
                           aw_ctx_row_bytes, aw_ctx_command_last};
    fifo #(
        .DATA_WIDTH (W_CTX_DATA_W),
        .DEPTH      (WRITE_OUTSTANDING_DEPTH)
    ) u_store_w_context_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en_i    (aw_ctx_pop),
        .wr_data_i  (w_ctx_data_in),
        .full_o     (w_ctx_full),
        .rd_en_i    (w_ctx_pop),
        .rd_data_o  (w_ctx_data_out),
        .empty_o    (w_ctx_empty)
    );

    // 当前 WLAST 握手的同一时钟沿切换描述，避免 burst 边界的装载空拍。
    assign w_ctx_pop = (!w_active_q || w_burst_done) && !w_ctx_empty;
    assign {w_addr, w_len, w_beat_offset, w_row_bytes, w_command_last} = w_ctx_data_out;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_addr_q         <= '0;
            w_len_q          <= '0;
            w_beat_offset_q  <= '0;
            w_row_bytes_q    <= '0;
            w_command_last_q <= 1'b0;
        end else if (w_ctx_pop) begin
            w_addr_q         <= w_addr;
            w_len_q          <= w_len;
            w_beat_offset_q  <= w_beat_offset;
            w_row_bytes_q    <= w_row_bytes;
            w_command_last_q <= w_command_last;
        end
    end
    assign w_burst_done = w_handshake && w_last;
    // W 通道当前是否正在处理一个 burst
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) 
            w_active_q <= 1'b0;
        else begin
            if (w_ctx_pop) begin
                w_active_q <= 1'b1;
            end else if (w_burst_done) begin
                w_active_q <= 1'b0;
            end
        end
    end
    
    assign w_last = w_beat_q == w_len_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_beat_q <= '0;
        end else if (w_ctx_pop) begin
            w_beat_q <= '0;
        end else if (w_handshake && !w_last) begin
            w_beat_q <= w_beat_q + 1'b1;
        end
    end

/********************** W 通道 **************************/
    // 数据按请求顺序返回，W 按独立描述顺序消费，不依赖读侧当前上下文。
    assign m_axi_wvalid_o = w_active_q && !data_fifo_empty && (!w_last || !resp_fifo_full);
    assign m_axi_wdata_o  = data_fifo_data_out;
    assign m_axi_wlast_o  = w_last;
    assign w_handshake    = m_axi_wvalid_o && m_axi_wready_i;

    assign w_global_beat = {1'b0, w_beat_offset_q} + w_beat_q;
    always @* begin
        w_strb = {BYTE_COUNT{1'b1}};
        if ((w_row_bytes_q[BYTE_LG2-1:0] != 0) &&
            (w_global_beat == ((w_row_bytes_q - 1'b1) >> BYTE_LG2))) begin
            w_strb = '0;
            for (strb_idx = 0; strb_idx < BYTE_COUNT; strb_idx = strb_idx + 1)
                if (strb_idx < w_row_bytes_q[BYTE_LG2-1:0])
                    w_strb[strb_idx] = 1'b1;
        end
    end
    assign m_axi_wstrb_o = w_strb;

/********************** B 通道 **************************/
    // WLAST 握手后登记一个 B 响应上下文；B 可以延迟返回。
    assign m_axi_bready_o = !resp_fifo_empty;
    assign b_handshake = m_axi_bvalid_i && m_axi_bready_o;

    // 保存W 数据已经发完、正在等待 B 响应的 burst 信息
    assign resp_fifo_push = w_burst_done;
    assign resp_fifo_data_in = {w_addr_q, w_command_last_q};
    fifo #(
        .DATA_WIDTH (RESP_DATA_W),
        .DEPTH      (WRITE_OUTSTANDING_DEPTH)
    ) u_store_resp_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en_i    (resp_fifo_push),
        .wr_data_i  (resp_fifo_data_in),
        .full_o     (resp_fifo_full),
        .rd_en_i    (resp_fifo_pop),
        .rd_data_o  (resp_fifo_data_out),
        .empty_o    (resp_fifo_empty)
    );
    assign resp_fifo_pop = b_handshake;
    assign { resp_fifo_addr, resp_fifo_command_last } = resp_fifo_data_out;

    // 非最后 burst 的错误先保存，最后一个 burst 返回时统一输出一次。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_fault_q      <= 1'b0;
            done_fault_addr_q <= '0;
        end else if (resp_fifo_pop) begin
            if (resp_fifo_command_last) begin
                done_fault_q <= 1'b0;
            end else if (m_axi_bresp_i[1] && !done_fault_q) begin
                done_fault_q      <= 1'b1;
                done_fault_addr_q <= resp_fifo_addr;
            end
        end
    end

    // 相同 AXI ID 保证 B 按序返回；只有命令最后一个 B 握手才释放 PC。
    fifo #(
        .DATA_WIDTH (32),
        .DEPTH      (CMD_QUEUE_DEPTH)
    ) u_store_pc_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en_i    (cmd_fifo_push),
        .wr_data_i  (cmd_pc_i),
        .full_o     (pc_fifo_full),
        .rd_en_i    (done_valid_o),
        .rd_data_o  (pc_fifo_data_out),
        .empty_o    (pc_fifo_empty)
    );
    
    assign done_valid_o = resp_fifo_pop && resp_fifo_command_last;
    assign done_fault_o = done_valid_o && (done_fault_q || m_axi_bresp_i[1]);
    assign done_pc_o    = pc_fifo_data_out;
    assign done_fault_addr_o = done_fault_q ? done_fault_addr_q : resp_fifo_addr;

    assign busy_o = gen_active_q || !cmd_fifo_empty || !pc_fifo_empty ||
                    !aw_ctx_empty || read_active_q || !w_ctx_empty ||
                    w_active_q || (read_reserved_q != 0) || !data_fifo_empty ||
                    !resp_fifo_empty;

endmodule
