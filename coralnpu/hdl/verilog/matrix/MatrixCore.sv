module MatrixCore (
    input  logic         clk,
    input  logic         rst_n,

    // 上游 Scoreboard 必须覆盖已接收及排队命令的 RAW/WAR/WAW，
    // 包括 AB/scale 源读取、C 读改写，以及 ZERO 的全部目标寄存器。
    // 矩阵计算命令通道。
    // 当前计算路径一次只接收一条命令。
    input  logic         cmd_valid_i,
    output logic         cmd_ready_o,
    input  logic [31:0]  cmd_pc_i,
    input  logic [1:0]   cmd_op_i,
    input  logic [2:0]   cmd_ms1_i,
    input  logic [2:0]   cmd_ms2_i,
    input  logic [2:0]   cmd_md_i,

    // mzero 命令接口。zero_reg_count_i 使用规范定义的数量编码：
    // 000/001/011/111 分别表示清零 1/2/4/8 个矩阵寄存器。
    input  logic          zero_valid_i,
    output logic          zero_ready_o,
    input  logic [31:0]   zero_pc_i,
    input  logic [2:0]    zero_md_i,
    input  logic [2:0]    zero_reg_count_i,

    // mem load/store 命令通道
    input  logic         mem_valid_i,
    output logic         mem_ready_o,
    input  logic [31:0]  mem_pc_i,
    input  logic [3:0]   mem_op_i,
    input  logic [2:0]   mem_reg_i,
    input  logic [1:0]   mem_elem_width_i,
    input  logic [31:0]  mem_base_i,
    input  logic [31:0]  mem_stride_i,

    input  logic [31:0]  cfg_m_i,
    input  logic [31:0]  cfg_k_i,
    input  logic [31:0]  cfg_n_i,
    input  logic         cfg_xmsaten_i,

    // 返回给标量侧的统一状态/完成信号。
    output logic         busy_o,
    output logic         done_valid_o,
    output logic         done_illegal_o,
    output logic [31:0]  done_pc_o,

    output logic         xmsat_set_valid_o,
    output logic         xmsat_set_bits_o,

    // mem 读写接口
    output logic         dmem_req_valid_o,
    output logic         dmem_req_write_o,
    output logic [31:0]  dmem_req_addr_o,
    output logic [255:0] dmem_req_wdata_o,
    output logic [31:0]  dmem_req_wmask_o,
    input  logic         dmem_busy_i,
    input  logic         dmem_rvalid_i,
    input  logic [255:0] dmem_rdata_i,

    // MatrixDma 专用的 512-bit AXI master。
    output logic         m_axi_arvalid_o,
    input  logic         m_axi_arready_i,
    output logic [0:0]   m_axi_arid_o,
    output logic [31:0]  m_axi_araddr_o,
    output logic [7:0]   m_axi_arlen_o,
    output logic [2:0]   m_axi_arsize_o,
    output logic [1:0]   m_axi_arburst_o,

    input  logic         m_axi_rvalid_i,
    output logic         m_axi_rready_o,
    input  logic [0:0]   m_axi_rid_i,
    input  logic [511:0] m_axi_rdata_i,
    input  logic [1:0]   m_axi_rresp_i,
    input  logic         m_axi_rlast_i,

    output logic         m_axi_awvalid_o,
    input  logic         m_axi_awready_i,
    output logic [0:0]   m_axi_awid_o,
    output logic [31:0]  m_axi_awaddr_o,
    output logic [7:0]   m_axi_awlen_o,
    output logic [2:0]   m_axi_awsize_o,
    output logic [1:0]   m_axi_awburst_o,
    output logic         m_axi_wvalid_o,
    input  logic         m_axi_wready_i,
    output logic [511:0] m_axi_wdata_o,
    output logic [63:0]  m_axi_wstrb_o,
    output logic         m_axi_wlast_o,
    input  logic         m_axi_bvalid_i,
    output logic         m_axi_bready_o,
    input  logic [0:0]   m_axi_bid_i,
    input  logic [1:0]   m_axi_bresp_i,

    // 调试口：直接透传到矩阵寄存器文件
    input  logic         tile_dbg_wr_en_i,
    input  logic [1:0]   tile_dbg_wr_reg_i,
    input  logic [16383:0] tile_dbg_wr_data_i,
    input  logic         acc_dbg_wr_en_i,
    input  logic [1:0]   acc_dbg_wr_reg_i,
    input  logic [32767:0] acc_dbg_wr_data_i,
    input  logic         dbg_tile_rd_en_i,
    input  logic [1:0]   dbg_tile_rd_reg_i,
    output logic [16383:0] dbg_tile_rd_data_o,
    input  logic         dbg_acc_rd_en_i,
    input  logic [1:0]   dbg_acc_rd_reg_i,
    output logic [32767:0] dbg_acc_rd_data_o
);

localparam [1:0] STATE_IDLE     = 2'd0;
localparam [1:0] STATE_EXEC     = 2'd1;
localparam [1:0] STATE_DONE     = 2'd2;

localparam int MAX_M = 64;
localparam int MAX_N = 64;
localparam int MAX_K = 64;
localparam int PE_MAX_ELEM_WIDTH = 8;
localparam int PE_ACC_WIDTH  = 32;
localparam int PE_TILE_COLS  = 32;
localparam int PE_TILE_ROWS  = 32;
localparam int PE_ACT_INPUT_W = PE_TILE_COLS * PE_MAX_ELEM_WIDTH;
localparam int PE_WEIGHT_INPUT_W = PE_TILE_ROWS * PE_MAX_ELEM_WIDTH;
localparam int PE_ACC_ROW_W  = PE_TILE_COLS * PE_ACC_WIDTH;

// MatrixMemOp 编码必须与 MatrixInterface.scala 中的 ChiselEnum 顺序一致。
localparam logic [3:0] MEM_LD_A      = 4'd0;
localparam logic [3:0] MEM_LD_B      = 4'd1;
localparam logic [3:0] MEM_LD_C      = 4'd2;
localparam logic [3:0] MEM_ST_A      = 4'd3;
localparam logic [3:0] MEM_ST_B      = 4'd4;
localparam logic [3:0] MEM_ST_C      = 4'd5;
localparam logic [3:0] MEM_LD_WHOLE  = 4'd6;
localparam logic [3:0] MEM_ST_WHOLE  = 4'd7;
localparam logic [3:0] MEM_LD_AT     = 4'd8;
localparam logic [3:0] MEM_LD_BT     = 4'd9;
localparam logic [3:0] MEM_LD_CT     = 4'd10;
localparam logic [3:0] MEM_ST_AT     = 4'd11;
localparam logic [3:0] MEM_ST_BT     = 4'd12;
localparam logic [3:0] MEM_ST_CT     = 4'd13;

// 这里只保存计算路径的状态。
// 访存搬运状态全部放在 MatrixDma 内部。
logic [1:0]                     state_q;
logic [31:0]                    pc_q;
logic                           illegal_q;
logic                           compute_done_pending_q;
// N/K 各最多拆成两个 block，因此一条 matmul 最多产生四个输出 block。
logic [2:0]                     pe_output_blocks_left_q;
logic [2:0]                     pe_rs1_q;
logic [2:0]                     pe_rs2_q;
logic [2:0]                     pe_rd_q;
logic [31:0]                    pe_cfg_m_q;
logic [31:0]                    pe_cfg_n_q;
logic [31:0]                    pe_cfg_k_q;

logic                           dma_ab_wr_en_w;
logic [1:0]                     dma_ab_wr_reg_w;
logic [5:0]                     dma_ab_wr_row_w;
logic [511:0]                   dma_ab_wr_data_w;
logic                           dma_ab_wr_dst_sel_w;
logic                           dma_c_wr_en_w;
logic                           dma_c_wr_half_w;
logic                           dma_c_wr_nblock_w;
logic                           dma_ab_matrix_wr_en_w;
logic                           dma_ab_scale_wr_en_w;

logic                           ab_rd0_valid_w;
logic [PE_ACT_INPUT_W-1:0]      ab_rd0_data_w;
logic                           ab_rd1_valid_w;
logic [PE_WEIGHT_INPUT_W-1:0]   ab_rd1_data1_w;
logic [PE_WEIGHT_INPUT_W-1:0]   ab_rd1_data2_unused;
logic                           ab_scale_rd0_valid_w;
logic [255:0]                   ab_scale_rd0_data_w;
logic                           ab_scale_rd1_valid_w;
logic [255:0]                   ab_scale_rd1_data_w;

logic [1:0]                     pe_rs1_scale_reg_w;
logic                           pe_rs1_scale_bank_w;
logic                           pe_rs1_scale_kblock_w;
logic                           pe_rs1_scale_read_valid_w;
logic [1:0]                     pe_rs2_scale_reg_w;
logic                           pe_rs2_scale_bank_w;
logic                           pe_rs2_scale_kblock_w;
logic                           pe_rs2_scale_read_valid_w;

logic                           pe_start_w;
logic                           pe_start_q;
logic                           pe_cmd_busy_w;
logic                           pe_finish_w;
logic                           pe_cmd_complete_w;
logic [2:0]                     pe_rs1_reg_w;
logic [5:0]                     pe_rs1_addr_w;
logic                           pe_rs1_read_valid_w;
logic [2:0]                     pe_rs2_reg_w;
logic [5:0]                     pe_rs2_addr_w;
logic                           pe_rs2_read_valid_w;
logic [2:0]                     pe_rd_read_reg_w;
logic [2:0]                     pe_rd_write_reg_w;
logic [5:0]                     pe_rd_read_addr_w;
logic [5:0]                     pe_rd_write_addr_w;
logic                           pe_rd_read_kblock_w;
logic                           pe_rd_write_kblock_w;
logic                           pe_rd_read_valid_w;
logic                           pe_rd_write_valid_w;
logic                           c_rd_data_valid_w;
logic [PE_ACC_ROW_W-1:0]        pe_rd_data_w;
logic [PE_ACC_ROW_W-1:0]        pe_result_data_w;
logic                           dma_c_rd_en_w;
logic [1:0]                     dma_c_rd_reg_w;
logic [5:0]                     dma_c_rd_addr_w;
logic                           dma_c_rd_nblock_w;
logic                           dma_c_rd_half_w;
logic                           dma_c_rd_valid_w;
logic [511:0]                   dma_c_rd_data_w;

logic                           pe_rs1_col_w;
logic                           pe_rs2_col_w;

logic                           mem_dir_w;
logic                           mem_ab_scale_sel_w; // 0: AB matrix, 1: AB scale
logic [1:0]                     mem_elem_bytes_w;
logic [7:0]                     mem_rows_w;
logic [7:0]                     mem_cols_w;
logic [31:0]                    mem_stride_w;

logic         illegal_cfg_w;
logic         illegal_reg_class_w;
logic         illegal_op_w;
logic         cmd_can_issue_w;
logic         cmd_issue_w;

logic         dma_busy_w;
logic         dma_mem_valid_w;
logic         dma_mem_store_w;
logic         dma_mem_ready_w;
logic         dma_done_valid_w;
logic         dma_done_illegal_w;
logic         dma_done_fault_w;
logic [31:0]  dma_done_pc_w;
logic [31:0]  dma_done_fault_addr_w;
logic         dma_m_axi_awvalid_w;
logic [0:0]   dma_m_axi_awid_w;
logic [31:0]  dma_m_axi_awaddr_w;
logic [7:0]   dma_m_axi_awlen_w;
logic [2:0]   dma_m_axi_awsize_w;
logic [1:0]   dma_m_axi_awburst_w;
logic         dma_m_axi_wvalid_w;
logic [511:0] dma_m_axi_wdata_w;
logic [63:0]  dma_m_axi_wstrb_w;
logic         dma_m_axi_wlast_w;
logic         dma_m_axi_bready_w;

logic dma_zero_valid_w;
logic dma_zero_ready_w;

// LOAD/ZERO share the DMA command FIFO; its single write port arbitrates them.
assign dma_zero_valid_w = zero_valid_i;
assign zero_ready_o = dma_zero_ready_w;

// 当前计算指令的合法性检查：
// - 两个源操作数必须是 tile 寄存器
// - 目标操作数必须是 acc 寄存器
// - 目前只打开第一种计算 op
assign illegal_cfg_w = (cfg_m_i == 0) || (cfg_n_i == 0) || (cfg_k_i == 0) ||
                       (cfg_m_i > MAX_M) || (cfg_n_i > MAX_N) || (cfg_k_i > MAX_K);
assign illegal_reg_class_w = cmd_ms1_i[2] || cmd_ms2_i[2] || !cmd_md_i[2];
assign illegal_op_w = (cmd_op_i != 2'b00);

// Independent registers have separate SRAM banks. The upstream scoreboard
// excludes DMA writes to registers still read or written by the computation.
assign cmd_can_issue_w = (state_q == STATE_IDLE) && !pe_cmd_busy_w;
assign cmd_issue_w = cmd_valid_i && cmd_can_issue_w;
assign pe_start_w = pe_start_q;

// 命令参数先在 MatrixCore 锁存，下一拍再向 pe_ctrl 发 start。
// 否则 pe_ctrl 会在命令接收沿采到上一条命令（复位后为 0）的参数。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pe_start_q <= 1'b0;
    end else begin
        pe_start_q <= cmd_issue_w && !(illegal_cfg_w || illegal_reg_class_w || illegal_op_w);
    end
end

// pe_ctrl 对每个 K block 都会把 M 行结果写回一次。Core 在最后一个 K block
// 的最后一行写回后结束命令，不依赖 pe_ctrl 内部保持型的 finish 信号。
assign pe_cmd_complete_w = pe_rd_write_valid_w &&
                           (pe_rd_write_addr_w == (pe_cfg_m_q[5:0] - 1'b1)) &&
                           (pe_output_blocks_left_q == 3'd1);

// 上游保证访存命令的寄存器类别、元素宽度及矩阵尺寸合法。
// Only STORE C has a source read adapter; other STORE variants remain disabled.
assign dma_mem_valid_w = mem_valid_i && (!mem_dir_w || (mem_op_i == MEM_ST_C));
assign dma_mem_store_w = mem_dir_w;
assign mem_ready_o = dma_mem_ready_w && (!mem_dir_w || (mem_op_i == MEM_ST_C));

// 将指令操作码归一化成 DMA 使用的方向、目的类型、元素字节数和二维形状。
// A 按 M x K 保存，B 按转置后的 N x K 保存，以匹配 FIR-WS 供数方向。
// A/B scale 的物理形状分别为 (K/32) x M 和 (K/32) x N。
// 软件必须保证用于分组的 K 维度是 32 的整数倍。
always @* begin
    mem_dir_w     = 1'b0;
    mem_ab_scale_sel_w = 1'b0;
    mem_elem_bytes_w = mem_elem_width_i;
    mem_rows_w    = cfg_m_i[7:0];
    mem_cols_w    = cfg_k_i[7:0];
    mem_stride_w  = mem_stride_i;

    case (mem_op_i)
        MEM_LD_A: begin
            mem_rows_w = cfg_m_i[7:0];
            mem_cols_w = cfg_k_i[7:0];
        end
        MEM_LD_B: begin
            mem_rows_w = cfg_n_i[7:0];
            mem_cols_w = cfg_k_i[7:0];
        end
        MEM_LD_C: begin
            mem_rows_w = cfg_m_i[7:0];
            mem_cols_w = cfg_n_i[7:0];
        end
        MEM_ST_A: begin
            mem_dir_w  = 1'b1;
            mem_rows_w = cfg_m_i[7:0];
            mem_cols_w = cfg_k_i[7:0];
        end
        MEM_ST_B: begin
            mem_dir_w  = 1'b1;
            mem_rows_w = cfg_k_i[7:0];
            mem_cols_w = cfg_n_i[7:0];
        end
        MEM_ST_C: begin
            mem_dir_w  = 1'b1;
            mem_rows_w = cfg_m_i[7:0];
            mem_cols_w = cfg_n_i[7:0];
        end
        MEM_LD_WHOLE, MEM_ST_WHOLE: begin
            mem_dir_w  = (mem_op_i == MEM_ST_WHOLE);
            // AB 寄存器物理容量为 64 行 x 64B；elemWidth 是字节数的 log2。
            mem_rows_w = 8'd64;
            mem_cols_w = 8'd64 >> mem_elem_width_i;
            // whole 指令没有 rs2 stride，连续物理行的步长固定为一行 64B。
            mem_stride_w = 32'd64;
        end
        MEM_LD_AT: begin
            mem_ab_scale_sel_w = 1'b1;
            mem_elem_bytes_w = 2'b00;
            // scale 在内存中按 K block 转置存放，每行包含全部 M scale。
            mem_rows_w    = cfg_k_i >> 5;
            mem_cols_w    = cfg_m_i[7:0];
        end
        MEM_LD_BT: begin
            mem_ab_scale_sel_w = 1'b1;
            mem_elem_bytes_w = 2'b00;
            // scale 在内存中按 K block 转置存放，每行包含全部 N scale。
            mem_rows_w    = cfg_k_i >> 5;
            mem_cols_w    = cfg_n_i[7:0];
        end
        MEM_ST_AT: begin
            mem_dir_w  = 1'b1;
            mem_rows_w = cfg_m_i[7:0];
            mem_cols_w = cfg_k_i[7:0];
        end
        MEM_ST_BT: begin
            mem_dir_w  = 1'b1;
            mem_rows_w = cfg_k_i[7:0];
            mem_cols_w = cfg_n_i[7:0];
        end
        // 当前没有 C scale；CT 保持普通 C 形状，目的仍为 ABMatrixReg。
        MEM_LD_CT: begin
            mem_rows_w = cfg_m_i[7:0];
            mem_cols_w = cfg_n_i[7:0];
        end
        MEM_ST_CT: begin
            mem_dir_w  = 1'b1;
            mem_rows_w = cfg_m_i[7:0];
            mem_cols_w = cfg_n_i[7:0];
        end
        default: begin
            mem_rows_w = '0;
            mem_cols_w = '0;
        end
    endcase
end

// 对外可见的状态，是以下两部分的合并结果：
// - 本地计算 FSM
// - DMA 子模块 FSM
assign cmd_ready_o = cmd_can_issue_w;
// Include pending completions. STATE_DONE is held if DMA uses the output.
assign busy_o = dma_busy_w || dma_done_valid_w ||
                (state_q != STATE_IDLE) || pe_cmd_busy_w ||
                compute_done_pending_q;
assign done_valid_o = dma_done_valid_w || compute_done_pending_q;
assign done_illegal_o = dma_done_valid_w ? dma_done_illegal_w :
                        (compute_done_pending_q && illegal_q);
assign done_pc_o = dma_done_valid_w ? dma_done_pc_w : pc_q;

// 当前 pe_ctrl 实现的是普通 32-bit 累加，不产生饱和事件。
assign xmsat_set_valid_o = 1'b0;
assign xmsat_set_bits_o = 1'b0;

// 当前调试端口尚未接入新的分 bank 矩阵寄存器。
assign dbg_tile_rd_data_o = '0;
assign dbg_acc_rd_data_o  = '0;

// pe_ctrl 根据当前 K block 直接产生 col：
// col=0 读取逻辑行低 32B，col=1 读取逻辑行高 32B。
// 这两个信号不能再从地址位推导，因为 ABMatrixReg 的逻辑地址和半行选择已分离。

// DMA 写回目的由命令中随数据返回的 dst_sel 决定。两个寄存器文件的写使能
// 严格互斥，避免 scale 数据同时覆盖 ABMatrixReg 中的矩阵数据。
assign dma_ab_matrix_wr_en_w = dma_ab_wr_en_w && !dma_ab_wr_dst_sel_w;
assign dma_ab_scale_wr_en_w  = dma_ab_wr_en_w &&  dma_ab_wr_dst_sel_w;

ABMatrixReg ab_regfile (
    .clk          ( clk                       ),
    .rst_n        ( rst_n                     ),
    .dma_wr_en_i  ( dma_ab_matrix_wr_en_w     ),
    .dma_wr_reg_i ( dma_ab_wr_reg_w           ),
    .dma_wr_row_i ( dma_ab_wr_row_w           ),
    .dma_wr_data_i( dma_ab_wr_data_w          ),
    .rd0_en_i     ( pe_rs1_read_valid_w       ),
    .rd0_reg_i    ( pe_rs1_reg_w[1:0]         ),
    .rd0_col_i    ( pe_rs1_col_w              ),
    .rd0_addr_i   ( pe_rs1_addr_w             ),
    .rd0_valid_o  ( ab_rd0_valid_w            ),
    .rd0_data_o   ( ab_rd0_data_w             ),
    .rd1_en_i     ( pe_rs2_read_valid_w       ),
    .rd1_reg_i    ( pe_rs2_reg_w[1:0]         ),
    .rd1_mode_i   ( 1'b0                      ),
    .rd1_col_i    ( pe_rs2_col_w              ),
    .rd1_addr_i   ( pe_rs2_addr_w             ),
    .rd1_valid_o  ( ab_rd1_valid_w            ),
    .rd1_data1_o  ( ab_rd1_data1_w            ),
    .rd1_data2_o  ( ab_rd1_data2_unused       )
);

// scale 计算通路尚未接入 PE；当前先完成 LD_AT/LD_BT 经 DMA 写入 scale SRAM。
ABScaleReg ab_scale_regfile (
    .clk          ( clk                       ),
    .rst_n        ( rst_n                     ),
    .dma_wr_en_i  ( dma_ab_scale_wr_en_w      ),
    .dma_wr_reg_i ( dma_ab_wr_reg_w           ),
    .dma_wr_kblock_i ( dma_ab_wr_row_w[0]     ),
    .dma_wr_data_i( dma_ab_wr_data_w          ),
    // rd0：先按输出 block 读取32个 A scale，再逐行消费。
    .rd0_en_i     ( pe_rs1_scale_read_valid_w ),
    .rd0_reg_i    ( pe_rs1_scale_reg_w        ),
    .rd0_row_i    ( pe_rs1_scale_bank_w       ),
    .rd0_kblock_i ( pe_rs1_scale_kblock_w     ),
    .rd0_valid_o  ( ab_scale_rd0_valid_w      ),
    .rd0_scale_o  ( ab_scale_rd0_data_w       ),
    // rd1：每个输出 block 一次读出当前 B tile 的 32 个逐列 scale。
    .rd1_en_i     ( pe_rs2_scale_read_valid_w ),
    .rd1_reg_i    ( pe_rs2_scale_reg_w        ),
    .rd1_row_i    ( pe_rs2_scale_bank_w       ),
    .rd1_kblock_i ( pe_rs2_scale_kblock_w     ),
    .rd1_valid_o  ( ab_scale_rd1_valid_w      ),
    .rd1_scale_o  ( ab_scale_rd1_data_w       )
);

// C 矩阵寄存器按 128B 行读写。读请求和同步 SRAM 返回使用独立
// valid 信号；C SRAM 的高低地址区对应 N block。
// 当前保留上游连线，pe_ctrl 的 K/N block 选择逻辑后续单独调整。
CMatrixReg c_regfile (
    .clk                ( clk                       ),
    .rst_n              ( rst_n                     ),
    .wr_en_i            ( pe_rd_write_valid_w       ),
    .wr_reg_i           ( pe_rd_write_reg_w[1:0]    ),
    .wr_addr_i          ( pe_rd_write_addr_w        ),
    .wr_nblock_i        ( pe_rd_write_kblock_w      ),
    .wr_data_i          ( pe_result_data_w          ),
    .dma_wr_en_i        ( dma_c_wr_en_w             ),
    .dma_wr_reg_i       ( dma_ab_wr_reg_w           ),
    .dma_wr_addr_i      ( dma_ab_wr_row_w           ),
    .dma_wr_nblock_i    ( dma_c_wr_nblock_w         ),
    .dma_wr_half_i      ( dma_c_wr_half_w           ),
    .dma_wr_data_i      ( dma_ab_wr_data_w          ),
    .dma_rd_en_i        ( dma_c_rd_en_w             ),
    .dma_rd_reg_i       ( dma_c_rd_reg_w            ),
    .dma_rd_addr_i      ( dma_c_rd_addr_w           ),
    .dma_rd_nblock_i    ( dma_c_rd_nblock_w         ),
    .dma_rd_half_i      ( dma_c_rd_half_w           ),
    .dma_rd_valid_o     ( dma_c_rd_valid_w          ),
    .dma_rd_data_o      ( dma_c_rd_data_w           ),
    .rd_en_i            ( pe_rd_read_valid_w        ),
    .rd_reg_i           ( pe_rd_read_reg_w[1:0]     ),
    .rd_addr_i          ( pe_rd_read_addr_w         ),
    .rd_nblock_i        ( pe_rd_read_kblock_w       ),
    .rd_valid_o         ( c_rd_data_valid_w         ),
    .rd_data_o          ( pe_rd_data_w              )
);

// 旧 direct-dmem 通路已被专用 AXI master 取代，暂时保留顶层端口兼容 Chisel。
assign dmem_req_valid_o = 1'b0;
assign dmem_req_write_o = 1'b0;
assign dmem_req_addr_o  = 32'b0;
assign dmem_req_wdata_o = 256'b0;
assign dmem_req_wmask_o = 32'b0;

assign m_axi_awvalid_o = dma_m_axi_awvalid_w;
assign m_axi_awid_o    = dma_m_axi_awid_w;
assign m_axi_awaddr_o  = dma_m_axi_awaddr_w;
assign m_axi_awlen_o   = dma_m_axi_awlen_w;
assign m_axi_awsize_o  = dma_m_axi_awsize_w;
assign m_axi_awburst_o = dma_m_axi_awburst_w;
assign m_axi_wvalid_o  = dma_m_axi_wvalid_w;
assign m_axi_wdata_o   = dma_m_axi_wdata_w;
assign m_axi_wstrb_o   = dma_m_axi_wstrb_w;
assign m_axi_wlast_o   = dma_m_axi_wlast_w;
assign m_axi_bready_o  = dma_m_axi_bready_w;

// DMA 共享 512-bit 数据、reg 和 row，分别使能 AB/scale 或 C 写口。
MatrixDma dma (
    .clk                    (clk                    ),
    .rst_n                  (rst_n                  ),
    .zero_valid_i           (dma_zero_valid_w       ),
    .zero_ready_o           (dma_zero_ready_w       ),
    .zero_pc_i              (zero_pc_i              ),
    .zero_md_i              (zero_md_i              ),
    .zero_reg_count_i       (zero_reg_count_i       ),
    .mem_valid_i            (dma_mem_valid_w        ),
    .mem_ready_o            (dma_mem_ready_w        ),
    .mem_store_i            (dma_mem_store_w        ),
    .mem_pc_i               (mem_pc_i               ),
    .mem_reg_i              (mem_reg_i              ),
    .mem_ab_scale_sel_i     (mem_ab_scale_sel_w     ),
    .mem_elem_bytes_i       (mem_elem_bytes_w       ),
    .mem_base_i             (mem_base_i             ),
    .mem_stride_i           (mem_stride_w           ),
    .mem_rows_i             (mem_rows_w             ),
    .mem_cols_i             (mem_cols_w             ),
    .matrix_rd_en_o         (dma_c_rd_en_w          ),
    .matrix_rd_reg_o        (dma_c_rd_reg_w         ),
    .matrix_rd_addr_o       (dma_c_rd_addr_w        ),
    .matrix_rd_nblock_o     (dma_c_rd_nblock_w      ),
    .matrix_rd_half_o       (dma_c_rd_half_w        ),
    .matrix_rd_source_sel_o (),
    .matrix_rd_valid_i      (dma_c_rd_valid_w       ),
    .matrix_rd_data_i       (dma_c_rd_data_w        ),
    .busy_o                 (dma_busy_w             ),
    .done_valid_o           (dma_done_valid_w       ),
    .done_illegal_o         (dma_done_illegal_w     ),
    .done_fault_o           (dma_done_fault_w       ),
    .done_pc_o              (dma_done_pc_w          ),
    .done_fault_addr_o      (dma_done_fault_addr_w  ),
    .ab_wr_en_o             (dma_ab_wr_en_w         ),
    .ab_wr_reg_o            (dma_ab_wr_reg_w        ),
    .ab_wr_row_o            (dma_ab_wr_row_w        ),
    .ab_wr_data_o           (dma_ab_wr_data_w       ),
    .ab_wr_dst_sel_o        (dma_ab_wr_dst_sel_w    ),
    .c_wr_en_o              (dma_c_wr_en_w          ),
    .c_wr_half_o            (dma_c_wr_half_w        ),
    .c_wr_nblock_o          (dma_c_wr_nblock_w      ),
    .m_axi_arvalid_o        (m_axi_arvalid_o        ),
    .m_axi_arready_i        (m_axi_arready_i        ),
    .m_axi_arid_o           (m_axi_arid_o           ),
    .m_axi_araddr_o         (m_axi_araddr_o         ),
    .m_axi_arlen_o          (m_axi_arlen_o          ),
    .m_axi_arsize_o         (m_axi_arsize_o         ),
    .m_axi_arburst_o        (m_axi_arburst_o        ),
    .m_axi_rvalid_i         (m_axi_rvalid_i         ),
    .m_axi_rready_o         (m_axi_rready_o         ),
    .m_axi_rid_i            (m_axi_rid_i            ),
    .m_axi_rdata_i          (m_axi_rdata_i          ),
    .m_axi_rresp_i          (m_axi_rresp_i          ),
    .m_axi_rlast_i          (m_axi_rlast_i          ),
    .m_axi_awvalid_o        (dma_m_axi_awvalid_w    ),
    .m_axi_awready_i        (m_axi_awready_i        ),
    .m_axi_awid_o           (dma_m_axi_awid_w       ),
    .m_axi_awaddr_o         (dma_m_axi_awaddr_w     ),
    .m_axi_awlen_o          (dma_m_axi_awlen_w      ),
    .m_axi_awsize_o         (dma_m_axi_awsize_w     ),
    .m_axi_awburst_o        (dma_m_axi_awburst_w    ),
    .m_axi_wvalid_o         (dma_m_axi_wvalid_w     ),
    .m_axi_wready_i         (m_axi_wready_i         ),
    .m_axi_wdata_o          (dma_m_axi_wdata_w      ),
    .m_axi_wstrb_o          (dma_m_axi_wstrb_w      ),
    .m_axi_wlast_o          (dma_m_axi_wlast_w      ),
    .m_axi_bvalid_i         (m_axi_bvalid_i         ),
    .m_axi_bready_o         (dma_m_axi_bready_w     ),
    .m_axi_bid_i            (m_axi_bid_i            ),
    .m_axi_bresp_i          (m_axi_bresp_i          ) 
);

// Coral 的 mmacc.w.b 使用 int8 A/B 和 32-bit C。pe_ctrl 负责 K 分块、
// 权重 ping/pong、脉动阵列推进以及逐行 C 写回。
pe_ctrl #(
    .MAX_ELEM_WIDTH ( PE_MAX_ELEM_WIDTH ),
    .ACC_WIDTH  ( PE_ACC_WIDTH  ),
    .TILE_COLS  ( PE_TILE_COLS  ),
    .TILE_ROWS  ( PE_TILE_ROWS  )
) u_pe_ctrl (
    .clk                    ( clk                       ),
    .rst_n                  ( rst_n                     ),
    .cfg_m_i                ( pe_cfg_m_q                ),
    .cfg_n_i                ( pe_cfg_n_q                ),
    .cfg_k_i                ( pe_cfg_k_q                ),
    .rs1_i                  ( pe_rs1_q                  ),
    .rs2_i                  ( pe_rs2_q                  ),
    .rd_i                   ( pe_rd_q                   ),
    .start_i                ( pe_start_w                ),
    .rs1_data_i             ( ab_rd0_data_w             ),
    .rs1_data_valid_i       ( ab_rd0_valid_w            ),
    .rs1_o                  ( pe_rs1_reg_w              ),
    .rs1_addr_o             ( pe_rs1_addr_w             ),
    .rs1_read_valid_o       ( pe_rs1_read_valid_w       ),
    .rs1_col_o              ( pe_rs1_col_w              ),
    .rs1_scale_data_i       ( ab_scale_rd0_data_w       ),
    .rs1_scale_data_valid_i ( ab_scale_rd0_valid_w  ),
    .rs1_scale_reg_o        ( pe_rs1_scale_reg_w        ),
    .rs1_scale_bank_o       ( pe_rs1_scale_bank_w       ),
    .rs1_scale_kblock_o     ( pe_rs1_scale_kblock_w     ),
    .rs1_scale_read_valid_o ( pe_rs1_scale_read_valid_w ),
    .rs2_data_i             ( ab_rd1_data1_w            ),
    .rs2_data_valid_i       ( ab_rd1_valid_w            ),
    .rs2_o                  ( pe_rs2_reg_w              ),
    .rs2_addr_o             ( pe_rs2_addr_w             ),
    .rs2_read_valid_o       ( pe_rs2_read_valid_w       ),
    .rs2_col_o              ( pe_rs2_col_w              ),
    .rs2_scale_data_i       ( ab_scale_rd1_data_w       ),
    .rs2_scale_data_valid_i ( ab_scale_rd1_valid_w  ),
    .rs2_scale_reg_o        ( pe_rs2_scale_reg_w        ),
    .rs2_scale_bank_o       ( pe_rs2_scale_bank_w       ),
    .rs2_scale_kblock_o     ( pe_rs2_scale_kblock_w     ),
    .rs2_scale_read_valid_o ( pe_rs2_scale_read_valid_w ),
    .rd_data_i              ( pe_rd_data_w              ),
    .rd_data_valid_i        ( c_rd_data_valid_w         ),
    .rd_read_o              ( pe_rd_read_reg_w          ),
    .rd_write_o             ( pe_rd_write_reg_w         ),
    .rd_read_addr_o         ( pe_rd_read_addr_w         ),
    .rd_write_addr_o        ( pe_rd_write_addr_w        ),
    .rd_read_kblock_o       ( pe_rd_read_kblock_w       ),
    .rd_write_kblock_o      ( pe_rd_write_kblock_w      ),
    .rd_write_valid_o       ( pe_rd_write_valid_w       ),
    .rd_read_valid_o        ( pe_rd_read_valid_w        ),
    .cmd_busy_o             ( pe_cmd_busy_w             ),
    .matmul_finish_o        ( pe_finish_w               ),
    .pe_array_o             ( pe_result_data_w          )
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_q <= STATE_IDLE;
        pc_q <= '0;
        illegal_q <= 1'b0;
        compute_done_pending_q <= 1'b0;
        pe_output_blocks_left_q <= '0;
        pe_rs1_q <= '0;
        pe_rs2_q <= '0;
        pe_rd_q <= '0;
        pe_cfg_m_q <= '0;
        pe_cfg_n_q <= '0;
        pe_cfg_k_q <= '0;
    end else begin
        case (state_q)
            STATE_IDLE: begin
                // 计算单元空闲时锁存命令，允许 DMA 同时执行。
                if (cmd_issue_w) begin
                    pc_q <= cmd_pc_i;
                    pe_rs1_q <= cmd_ms1_i;
                    pe_rs2_q <= cmd_ms2_i;
                    pe_rd_q <= cmd_md_i;
                    pe_cfg_m_q <= cfg_m_i;
                    pe_cfg_n_q <= cfg_n_i;
                    pe_cfg_k_q <= cfg_k_i;
                    if (illegal_cfg_w || illegal_reg_class_w || illegal_op_w) begin
                        illegal_q <= 1'b1;
                        pe_output_blocks_left_q <= '0;
                        compute_done_pending_q <= 1'b1;
                        state_q <= STATE_DONE;
                    end else begin
                        illegal_q <= 1'b0;
                        if ((cfg_k_i > PE_TILE_ROWS) && (cfg_n_i > PE_TILE_COLS))
                            pe_output_blocks_left_q <= 3'd4;
                        else if ((cfg_k_i > PE_TILE_ROWS) || (cfg_n_i > PE_TILE_COLS))
                            pe_output_blocks_left_q <= 3'd2;
                        else
                            pe_output_blocks_left_q <= 3'd1;
                        state_q <= STATE_EXEC;
                    end
                end
            end
            STATE_EXEC: begin
                // 每个 K block 都会写回 M 行；前面的 block 只递减计数，
                // 最后一个 block 的最后一行写回后才结束整条命令。
                if (pe_rd_write_valid_w &&
                    (pe_rd_write_addr_w == (pe_cfg_m_q[5:0] - 1'b1))) begin
                    if (pe_cmd_complete_w) begin
                        pe_output_blocks_left_q <= '0;
                        compute_done_pending_q <= 1'b1;
                        state_q <= STATE_DONE;
                    end else begin
                        pe_output_blocks_left_q <= pe_output_blocks_left_q - 3'd1;
                    end
                end
            end
            STATE_DONE: begin
                // The shared completion port reports DMA first. Keep the
                // compute completion pending until a cycle without DMA done.
                if (compute_done_pending_q && !dma_done_valid_w) begin
                    compute_done_pending_q <= 1'b0;
                    state_q <= STATE_IDLE;
                end
            end
            default: begin
                state_q <= STATE_IDLE;
            end
        endcase
    end
end

endmodule
