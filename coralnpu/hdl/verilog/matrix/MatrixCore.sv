module MatrixCore (
    input  logic         clk,
    input  logic         rst_n,

    // 矩阵计算命令通道。
    // 当前计算路径一次只接收一条命令。
    input  logic         cmd_valid_i,
    output logic         cmd_ready_o,
    input  logic [31:0]  cmd_pc_i,
    input  logic [1:0]   cmd_op_i,
    input  logic [2:0]   cmd_ms1_i,
    input  logic [2:0]   cmd_ms2_i,
    input  logic [2:0]   cmd_md_i,

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

localparam int MAX_M = 32;
localparam int MAX_N = 32;
localparam int MAX_K = 64;

// 这里只保存计算路径的状态。
// 访存搬运状态全部放在 MatrixDma 内部。
logic [1:0] state_q;
logic [2:0] ms1_q;
logic [2:0] ms2_q;
logic [2:0] md_q;
logic [31:0] pc_q;
logic       illegal_q;
logic       sat_q;

logic        tile_rd0_en_w;
logic        tile_rd1_en_w;
logic [1:0]  tile_rd0_reg_w;
logic [1:0]  tile_rd1_reg_w;
logic [16383:0] tile_rd0_data_w;
logic [16383:0] tile_rd1_data_w;

logic        acc_rd_en_w;
logic [1:0]  acc_rd_reg_w;
logic [32767:0] acc_rd_data_w;

logic        acc_wr_en_w;
logic [1:0]  acc_wr_reg_w;
logic [32767:0] acc_wr_data_w;
logic        tile_mem_wr_en_w;
logic [1:0]  tile_mem_wr_reg_w;
logic [16383:0] tile_mem_wr_data_w;
logic        acc_mem_wr_en_w;
logic [1:0]  acc_mem_wr_reg_w;
logic [32767:0] acc_mem_wr_data_w;
logic        tile_mem_rd_en_w;
logic [1:0]  tile_mem_rd_reg_w;
logic [16383:0] tile_mem_rd_data_w;
logic        acc_mem_rd_en_w;
logic [1:0]  acc_mem_rd_reg_w;
logic [32767:0] acc_mem_rd_data_w;

logic [32767:0] mac_c_acc_w;
logic         mac_sat_w;
logic         illegal_cfg_w;
logic         illegal_reg_class_w;
logic         illegal_op_w;
logic [1:0]   ms1_idx_w;
logic [1:0]   ms2_idx_w;
logic [1:0]   md_idx_w;

logic         cmd_can_issue_w;
logic         mem_can_issue_w;
logic         cmd_issue_w;
logic         mem_issue_w;

logic         dma_busy_w;
logic         dma_done_valid_w;
logic         dma_done_illegal_w;
logic [31:0]  dma_done_pc_w;

// 当前计算指令的合法性检查：
// - 两个源操作数必须是 tile 寄存器
// - 目标操作数必须是 acc 寄存器
// - 目前只打开第一种计算 op
assign illegal_cfg_w = (cfg_m_i > MAX_M) || (cfg_n_i > MAX_N) || (cfg_k_i > MAX_K);
assign illegal_reg_class_w = cmd_ms1_i[2] || cmd_ms2_i[2] || !cmd_md_i[2];
assign illegal_op_w = (cmd_op_i != 2'b00);
assign ms1_idx_w = ms1_q[1:0];
assign ms2_idx_w = ms2_q[1:0];
assign md_idx_w = md_q[1:0];

// 当前先允许计算路径与 DMA 路径独立发射，可重叠执行。
// 这一版暂不处理寄存器冲突、写口冲突和完成冲突。
assign cmd_can_issue_w = (state_q == STATE_IDLE);
assign mem_can_issue_w = !dma_busy_w && !dma_done_valid_w;
assign cmd_issue_w = cmd_valid_i && cmd_can_issue_w;
assign mem_issue_w = mem_valid_i && mem_can_issue_w;

// 计算路径读取两个 tile 源寄存器，以及一个 acc 目标/累加寄存器。
assign tile_rd0_en_w = (state_q == STATE_EXEC);
assign tile_rd1_en_w = (state_q == STATE_EXEC);
assign tile_rd0_reg_w = ms1_idx_w;
assign tile_rd1_reg_w = ms2_idx_w;

assign acc_rd_en_w = (state_q == STATE_EXEC);
assign acc_rd_reg_w = md_idx_w;

assign acc_wr_en_w = (state_q == STATE_EXEC) && !illegal_q;
assign acc_wr_reg_w = md_idx_w;
assign acc_wr_data_w = mac_c_acc_w;

// 对外可见的状态，是以下两部分的合并结果：
// - 本地计算 FSM
// - DMA 子模块 FSM
assign cmd_ready_o = cmd_can_issue_w;
assign mem_ready_o = mem_can_issue_w;
assign busy_o = dma_busy_w || ((state_q != STATE_IDLE) && (state_q != STATE_DONE));
assign done_valid_o = dma_done_valid_w || (state_q == STATE_DONE);
assign done_illegal_o = dma_done_valid_w ? dma_done_illegal_w : ((state_q == STATE_DONE) && illegal_q);
assign done_pc_o = dma_done_valid_w ? dma_done_pc_w : pc_q;

// 饱和标志只由计算路径产生，DMA 路径不会设置它。
assign xmsat_set_valid_o = (state_q == STATE_DONE) && !illegal_q && sat_q;
assign xmsat_set_bits_o = sat_q;

// 共享的矩阵寄存器文件：
// - 计算路径使用 tile_rd*/acc_rd/acc_wr
// - DMA 路径使用整寄存器读写侧带端口
// - 调试路径直接透传
MatrixRegFile regfile (
    .clk(clk),
    .rst_n(rst_n),

    .tile_rd0_en_i(tile_rd0_en_w),
    .tile_rd0_reg_i(tile_rd0_reg_w),
    .tile_rd0_data_o(tile_rd0_data_w),

    .tile_rd1_en_i(tile_rd1_en_w),
    .tile_rd1_reg_i(tile_rd1_reg_w),
    .tile_rd1_data_o(tile_rd1_data_w),

    .acc_rd_en_i(acc_rd_en_w),
    .acc_rd_reg_i(acc_rd_reg_w),
    .acc_rd_data_o(acc_rd_data_w),

    .acc_wr_en_i(acc_wr_en_w),
    .acc_wr_reg_i(acc_wr_reg_w),
    .acc_wr_data_i(acc_wr_data_w),

    .tile_mem_wr_en_i(tile_mem_wr_en_w),
    .tile_mem_wr_reg_i(tile_mem_wr_reg_w),
    .tile_mem_wr_data_i(tile_mem_wr_data_w),
    .acc_mem_wr_en_i(acc_mem_wr_en_w),
    .acc_mem_wr_reg_i(acc_mem_wr_reg_w),
    .acc_mem_wr_data_i(acc_mem_wr_data_w),
    .tile_mem_rd_en_i(tile_mem_rd_en_w),
    .tile_mem_rd_reg_i(tile_mem_rd_reg_w),
    .tile_mem_rd_data_o(tile_mem_rd_data_w),
    .acc_mem_rd_en_i(acc_mem_rd_en_w),
    .acc_mem_rd_reg_i(acc_mem_rd_reg_w),
    .acc_mem_rd_data_o(acc_mem_rd_data_w),

    .tile_dbg_wr_en_i(tile_dbg_wr_en_i),
    .tile_dbg_wr_reg_i(tile_dbg_wr_reg_i),
    .tile_dbg_wr_data_i(tile_dbg_wr_data_i),
    .acc_dbg_wr_en_i(acc_dbg_wr_en_i),
    .acc_dbg_wr_reg_i(acc_dbg_wr_reg_i),
    .acc_dbg_wr_data_i(acc_dbg_wr_data_i),
    .dbg_tile_rd_en_i(dbg_tile_rd_en_i),
    .dbg_tile_rd_reg_i(dbg_tile_rd_reg_i),
    .dbg_tile_rd_data_o(dbg_tile_rd_data_o),
    .dbg_acc_rd_en_i(dbg_acc_rd_en_i),
    .dbg_acc_rd_reg_i(dbg_acc_rd_reg_i),
    .dbg_acc_rd_data_o(dbg_acc_rd_data_o)
);

// DMA 子模块负责矩阵 load/store 的全部 dmem 侧控制。
MatrixDma dma (
    .clk(clk),
    .rst_n(rst_n),
    .mem_issue_i(mem_issue_w),
    .mem_pc_i(mem_pc_i),
    .mem_op_i(mem_op_i),
    .mem_reg_i(mem_reg_i),
    .mem_elem_width_i(mem_elem_width_i),
    .mem_base_i(mem_base_i),
    .mem_stride_i(mem_stride_i),
    .illegal_cfg_i(illegal_cfg_w),
    .busy_o(dma_busy_w),
    .done_valid_o(dma_done_valid_w),
    .done_illegal_o(dma_done_illegal_w),
    .done_pc_o(dma_done_pc_w),
    .dmem_req_valid_o(dmem_req_valid_o),
    .dmem_req_write_o(dmem_req_write_o),
    .dmem_req_addr_o(dmem_req_addr_o),
    .dmem_req_wdata_o(dmem_req_wdata_o),
    .dmem_req_wmask_o(dmem_req_wmask_o),
    .dmem_busy_i(dmem_busy_i),
    .dmem_rvalid_i(dmem_rvalid_i),
    .dmem_rdata_i(dmem_rdata_i),
    .tile_mem_wr_en_o(tile_mem_wr_en_w),
    .tile_mem_wr_reg_o(tile_mem_wr_reg_w),
    .tile_mem_wr_data_o(tile_mem_wr_data_w),
    .acc_mem_wr_en_o(acc_mem_wr_en_w),
    .acc_mem_wr_reg_o(acc_mem_wr_reg_w),
    .acc_mem_wr_data_o(acc_mem_wr_data_w),
    .tile_mem_rd_en_o(tile_mem_rd_en_w),
    .tile_mem_rd_reg_o(tile_mem_rd_reg_w),
    .tile_mem_rd_data_i(tile_mem_rd_data_w),
    .acc_mem_rd_en_o(acc_mem_rd_en_w),
    .acc_mem_rd_reg_o(acc_mem_rd_reg_w),
    .acc_mem_rd_data_i(acc_mem_rd_data_w)
);

// 纯计算数据通路：A tile、B tile、旧 C acc，生成新 C acc。
MatrixMacArray mac_array (
    .a_tile_i(tile_rd0_data_w),
    .b_tile_i(tile_rd1_data_w),
    .c_acc_i(acc_rd_data_w),
    .cfg_m_i(cfg_m_i),
    .cfg_k_i(cfg_k_i),
    .cfg_n_i(cfg_n_i),
    .sat_en_i(cfg_xmsaten_i),
    .c_acc_o(mac_c_acc_w),
    .sat_o(mac_sat_w)
);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_q <= STATE_IDLE;
        ms1_q <= '0;
        ms2_q <= '0;
        md_q <= '0;
        pc_q <= '0;
        illegal_q <= 1'b0;
        sat_q <= 1'b0;
    end else begin
        case (state_q)
            STATE_IDLE: begin
                // 当整个矩阵核空闲时，锁存一条新的计算命令。
                if (cmd_issue_w) begin
                    pc_q <= cmd_pc_i;
                    ms1_q <= cmd_ms1_i;
                    ms2_q <= cmd_ms2_i;
                    md_q <= cmd_md_i;
                    sat_q <= 1'b0;
                    if (illegal_cfg_w || illegal_reg_class_w || illegal_op_w) begin
                        illegal_q <= 1'b1;
                        state_q <= STATE_DONE;
                    end else begin
                        illegal_q <= 1'b0;
                        state_q <= STATE_EXEC;
                    end
                end
            end
            STATE_EXEC: begin
                // MAC 结果是组合产生的，在这里登记完成。
                sat_q <= mac_sat_w;
                state_q <= STATE_DONE;
            end
            STATE_DONE: begin
                // done 保持一拍，然后回到空闲态。
                state_q <= STATE_IDLE;
            end
            default: begin
                state_q <= STATE_IDLE;
            end
        endcase
    end
end

endmodule
