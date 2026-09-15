/* 矩阵寄存器读出数据处理：一级弹性缓存，格式转换接口默认直通。 */
module MatrixReadDataProcess #(
    parameter int DATA_W = 512
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             in_valid_i,
    output logic             in_ready_o,
    input  logic [DATA_W-1:0] in_data_i,
    output logic             out_valid_o,
    input  logic             out_ready_i,
    output logic [DATA_W-1:0] out_data_o
);
    logic [DATA_W-1:0] data_q;
    logic              valid_q;

    // 当前先保持原始编码直通。定制 FP32 转换应在这里替换。
    assign out_data_o  = data_q;
    assign out_valid_o = valid_q;
    assign in_ready_o  = !valid_q || out_ready_i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_q  <= '0;
            valid_q <= 1'b0;
        end else if (in_ready_o) begin
            valid_q <= in_valid_i;
            if (in_valid_i)
                data_q <= in_data_i;
        end
    end
endmodule

/* 
    矩阵寄存器到 DDR 的通用 Store 引擎。 
    1. 当前DMA 对矩阵寄存器读出默认 发出请求后会的下一周期 即可返回数据。 否则逻辑需要修改。

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
    localparam int READ_CAPACITY     = DATA_FIFO_DEPTH + 1;
    localparam int READ_COUNT_W      = $clog2(READ_CAPACITY + 1);
    localparam int OUT_COUNT_W       = $clog2(WRITE_OUTSTANDING_DEPTH + 1);

    localparam int CMD_DATA_W = 32 + REG_IDX_W + 2 + AXI_ADDR_W + 32 + 8 + ROW_BYTES_W + 8;

    // 一个 entry 对应一个不跨 4KB 的 AXI burst。
    localparam int AW_CTX_DATA_W = AXI_ADDR_W + 8 + REG_IDX_W + 2 + ROW_IDX_W + 8 + ROW_BYTES_W + 32 + 1;
    localparam int RESP_DATA_W = AXI_ADDR_W + 32 + 1;

    logic [CMD_DATA_W-1:0]      cmd_fifo_data_in;
    logic [CMD_DATA_W-1:0]      cmd_fifo_data_out;
    logic                       cmd_fifo_full;
    logic                       cmd_fifo_empty;
    logic                       cmd_fifo_push;
    logic                       cmd_fifo_pop;
    logic [31:0]                cmd_fifo_pc;
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
    logic [31:0]                gen_pc_q;
    logic [REG_IDX_W-1:0]       gen_reg_q;
    logic [1:0]                 gen_source_sel_q;
    logic [AXI_ADDR_W-1:0]      gen_addr_q;
    logic [31:0]                gen_stride_q;
    logic [7:0]                 gen_rows_q;
    logic [7:0]                 gen_row_len_q;
    logic [ROW_BYTES_W-1:0]      gen_row_bytes_q;
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
    logic [31:0]                aw_ctx_pc;
    logic                       aw_ctx_command_last;

    logic [OUT_COUNT_W-1:0]     axi_outstanding_q;
    logic                       aw_handshake;
    logic                       b_handshake;
    logic                       aw_can_issue;

    logic                       w_active_q;
    logic                       w_context_load;
    logic [AXI_ADDR_W-1:0]      w_addr_q;
    logic [7:0]                 w_len_q;
    logic [REG_IDX_W-1:0]       w_reg_q;
    logic [1:0]                 w_source_sel_q;
    logic [ROW_IDX_W-1:0]       w_matrix_row_q;
    logic [7:0]                 w_beat_offset_q;
    logic [ROW_BYTES_W-1:0]     w_row_bytes_q;
    logic [31:0]                w_pc_q;
    logic                       w_command_last_q;
    logic [7:0]                 w_beat_q;
    logic [8:0]                 w_beat_p1;
    logic [8:0]                 w_global_beat;
    logic                       w_last;
    logic [AXI_DATA_W/8-1:0]    w_strb;
    logic                       w_burst_done;
    integer                     strb_idx;

    // 只有深度 2 的 beat FIFO，不再缓存整行矩阵数据。
    logic [AXI_DATA_W-1:0]          data_fifo_data_out;
    logic                           data_fifo_empty;
    logic                           data_fifo_full;
    logic                           data_fifo_push;
    logic                           data_fifo_pop;
    logic [AXI_DATA_W-1:0]          processed_data;
    logic                            processed_valid;
    logic                            process_in_ready;
    logic                            process_out_ready;

    logic                           read_done_q;
    logic [READ_COUNT_W-1:0]         read_reserved_q;
    logic [7:0]                     read_issue_beat_q;
    logic                           read_issue_done_q;
    logic [7:0]                     read_beat_q;
    logic [8:0]                     read_beat_p1;
    logic [8:0]                     read_last_beat;

    logic [RESP_DATA_W-1:0]         resp_fifo_data_in;
    logic [RESP_DATA_W-1:0]         resp_fifo_data_out;
    logic                           resp_fifo_full;
    logic                           resp_fifo_empty;
    logic                           resp_fifo_push;
    logic                           resp_fifo_pop;
    logic [AXI_ADDR_W-1:0]          resp_fifo_addr;
    logic [31:0]                    resp_fifo_pc;
    logic                           resp_fifo_command_last;
    logic                           done_fault_q;
    logic [AXI_ADDR_W-1:0]          done_fault_addr_q;

    integer idx;

    // len 统一表示 beat 数减一，0 表示 1 beat；上游保证列数合法且非零。
    assign cmd_row_bytes_calc = {2'b0, cmd_cols_i} << cmd_elem_bytes_i;
    assign cmd_len_calc = (cmd_row_bytes_calc - 1'b1) >> BYTE_LG2;

    assign cmd_fifo_data_in = { cmd_pc_i,cmd_reg_i,cmd_source_sel_i,cmd_base_i,cmd_stride_i,
                                cmd_rows_i,cmd_row_bytes_calc,cmd_len_calc};
    assign cmd_ready_o   = !cmd_fifo_full;
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

    assign { cmd_fifo_pc, cmd_fifo_reg, cmd_fifo_source_sel, cmd_fifo_base,
        cmd_fifo_stride, cmd_fifo_rows, cmd_fifo_row_bytes, cmd_fifo_len } = cmd_fifo_data_out;

    // 命令参数寄存器。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gen_pc_q         <= '0;
            gen_reg_q        <= '0;
            gen_source_sel_q <= '0;
            gen_stride_q     <= '0;
            gen_row_len_q    <= '0;
            gen_row_bytes_q  <= '0;
            gen_rows_q       <= '0;
        end else if (cmd_fifo_pop) begin
            gen_pc_q         <= cmd_fifo_pc;
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
    // TODO 命令的最后一次burst才需要保存一次 pc , 但需要改变一下fifo结构, 后续有空可以优化
    assign aw_ctx_data_in = {gen_segment_addr, gen_segment_len, gen_reg_q, gen_source_sel_q,
        gen_row_q, gen_segment_offset_q, gen_row_bytes_q, gen_pc_q, gen_command_last };

    // 生成器直接驱动 AW，握手时将同一份描述写入上下文 FIFO。
    // 上下文 FIFO 占用数不超过 outstanding 数，且深度相同；有额度就一定有空间。
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
        aw_ctx_beat_offset, aw_ctx_row_bytes, aw_ctx_pc, aw_ctx_command_last} = aw_ctx_data_out;

    // AW 上下文队首装载到 W 发送器，保证 W 与 AW 顺序一致。
    assign w_context_load = !w_active_q && !aw_ctx_empty;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_addr_q         <= '0;
            w_len_q          <= '0;
            w_reg_q          <= '0;
            w_source_sel_q   <= '0;
            w_matrix_row_q   <= '0;
            w_beat_offset_q  <= '0;
            w_row_bytes_q    <= '0;
            w_pc_q           <= '0;
            w_command_last_q <= 1'b0;
        end else if (w_context_load) begin
            w_addr_q         <= aw_ctx_addr;
            w_len_q          <= aw_ctx_len;
            w_reg_q          <= aw_ctx_reg;
            w_source_sel_q   <= aw_ctx_source_sel;
            w_matrix_row_q   <= aw_ctx_matrix_row;
            w_beat_offset_q  <= aw_ctx_beat_offset;
            w_row_bytes_q    <= aw_ctx_row_bytes;
            w_pc_q           <= aw_ctx_pc;
            w_command_last_q <= aw_ctx_command_last;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_active_q       <= 1'b0;
        end 
        else begin
            if (w_context_load) begin
                w_active_q       <= 1'b1;
            end else if (w_burst_done) begin
                w_active_q <= 1'b0;
            end
        end
    end

    assign aw_ctx_pop = w_burst_done;
    assign w_beat_p1 = {1'b0, w_beat_q} + 1'b1;
    assign w_global_beat = {1'b0, w_beat_offset_q} + w_beat_q;
    assign w_last = w_beat_q == w_len_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_beat_q <= '0;
        end else if (w_context_load) begin
            w_beat_q <= '0;
        end else if (data_fifo_pop) begin
            if (w_last)
                w_beat_q <= '0;
            else
                w_beat_q <= w_beat_p1[7:0];
        end
    end

    assign b_handshake = resp_fifo_pop;

    // 当前 W burst 的矩阵读请求。
    assign read_beat_p1 = {1'b0, read_beat_q} + 1'b1;
    assign read_last_beat = {1'b0, w_beat_offset_q} + {1'b0, w_len_q};
    // 固定一拍返回：请求发出即预留空间，W 握手后释放，包含在途数据。
    // FIFO 两拍 + 处理寄存器一拍；不能只用当前 ready 判断下一拍的容量。
    assign matrix_rd_en_o = w_active_q && !read_done_q &&
                            !read_issue_done_q &&
                            ((read_reserved_q < READ_CAPACITY) || data_fifo_pop) &&
                            ({1'b0, read_issue_beat_q} <= read_last_beat);
    assign matrix_rd_reg_o        = w_reg_q;
    assign matrix_rd_addr_o       = w_matrix_row_q;
    assign matrix_rd_nblock_o     = read_issue_beat_q[1];
    assign matrix_rd_half_o       = read_issue_beat_q[0];
    assign matrix_rd_source_sel_o = w_source_sel_q;
    assign data_fifo_push = processed_valid && process_out_ready;

    assign process_out_ready = !data_fifo_full;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_reserved_q <= '0;
        end else begin
            case ({matrix_rd_en_o, data_fifo_pop})
                2'b10: read_reserved_q <= read_reserved_q + 1'b1;
                2'b01: read_reserved_q <= read_reserved_q - 1'b1;
                default: ;
            endcase
        end
    end

    MatrixReadDataProcess #(
        .DATA_W (AXI_DATA_W)
    ) u_store_read_data_process (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_valid_i  (w_active_q && matrix_rd_valid_i),
        .in_ready_o  (process_in_ready),
        .in_data_i   (matrix_rd_data_i),
        .out_valid_o (processed_valid),
        .out_ready_i (process_out_ready),
        .out_data_o  (processed_data)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_issue_beat_q <= '0;
            read_issue_done_q <= 1'b0;
        end else if (w_context_load) begin
            read_issue_beat_q <= aw_ctx_beat_offset;
            read_issue_done_q <= 1'b0;
        end else if (matrix_rd_en_o) begin
            if ({1'b0, read_issue_beat_q} == read_last_beat) begin
                read_issue_beat_q <= '0;
                read_issue_done_q <= 1'b1;
            end else begin
                read_issue_beat_q <= read_issue_beat_q + 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_done_q <= 1'b0;
        end else if (w_context_load) begin
            read_done_q <= 1'b0;
        end else if (matrix_rd_valid_i &&
                     ({1'b0, read_beat_q} == read_last_beat)) begin
            read_done_q <= 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_beat_q <= '0;
        end else if (w_context_load) begin
            read_beat_q <= aw_ctx_beat_offset;
        end else if (matrix_rd_valid_i) begin
            if ({1'b0, read_beat_q} == read_last_beat)
                read_beat_q <= '0;
            else
                read_beat_q <= read_beat_p1[7:0];
        end
    end

    // 深度 2 的 beat FIFO，使用工程统一 FIFO 模块。
    fifo #(
        .DATA_WIDTH (AXI_DATA_W),
        .DEPTH      (DATA_FIFO_DEPTH)
    ) u_store_data_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en_i    (data_fifo_push),
        .wr_data_i  (processed_data),
        .full_o     (data_fifo_full),
        .rd_en_i    (data_fifo_pop),
        .rd_data_o  (data_fifo_data_out),
        .empty_o    (data_fifo_empty)
    );

    // W 通道只能发送当前 AW 队首 burst 的数据。
    assign m_axi_wvalid_o = w_active_q && !data_fifo_empty &&
                            (!w_last || !resp_fifo_full);
    assign m_axi_wdata_o  = data_fifo_data_out;
    assign m_axi_wlast_o  = w_last;
    assign data_fifo_pop  = m_axi_wvalid_o && m_axi_wready_i;
    assign w_burst_done   = data_fifo_pop && w_last;

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

    // WLAST 握手后登记一个 B 响应上下文；B 可以延迟返回。
    assign resp_fifo_push = w_burst_done;
    assign resp_fifo_data_in = {w_addr_q, w_pc_q, w_command_last_q};
    assign m_axi_bready_o = !resp_fifo_empty;
    assign resp_fifo_pop = m_axi_bvalid_i && m_axi_bready_o;

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

    assign {
        resp_fifo_addr,
        resp_fifo_pc,
        resp_fifo_command_last
    } = resp_fifo_data_out;

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

    assign done_valid_o = resp_fifo_pop && resp_fifo_command_last;
    assign done_fault_o = done_valid_o && (done_fault_q || m_axi_bresp_i[1]);
    assign done_pc_o    = resp_fifo_pc;
    assign done_fault_addr_o = done_fault_q ? done_fault_addr_q : resp_fifo_addr;

    assign busy_o = gen_active_q || !cmd_fifo_empty ||
                    !aw_ctx_empty || w_active_q || !data_fifo_empty ||
                    !resp_fifo_empty;
endmodule
