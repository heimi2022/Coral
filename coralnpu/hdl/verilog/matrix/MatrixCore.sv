module MatrixCore (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         cmd_valid_i,
    output logic         cmd_ready_o,
    input  logic [31:0]  cmd_pc_i,
    input  logic [1:0]   cmd_op_i,
    input  logic [2:0]   cmd_ms1_i,
    input  logic [2:0]   cmd_ms2_i,
    input  logic [2:0]   cmd_md_i,

    input  logic [31:0]  cfg_m_i,
    input  logic [31:0]  cfg_k_i,
    input  logic [31:0]  cfg_n_i,
    input  logic         cfg_xmsaten_i,

    output logic         busy_o,
    output logic         done_valid_o,
    output logic         done_illegal_o,
    output logic [31:0]  done_pc_o,

    output logic         xmsat_set_valid_o,
    output logic         xmsat_set_bits_o,

    // debug preload passthrough
    input  logic         tile_dbg_wr_en_i,
    input  logic [1:0]   tile_dbg_wr_reg_i,
    input  logic [1023:0] tile_dbg_wr_data_i,
    input  logic         acc_dbg_wr_en_i,
    input  logic [1:0]   acc_dbg_wr_reg_i,
    input  logic [511:0] acc_dbg_wr_data_i,
    input  logic         dbg_tile_rd_en_i,
    input  logic [1:0]   dbg_tile_rd_reg_i,
    output logic [1023:0] dbg_tile_rd_data_o,
    input  logic         dbg_acc_rd_en_i,
    input  logic [1:0]   dbg_acc_rd_reg_i,
    output logic [511:0] dbg_acc_rd_data_o
);

localparam [1:0] STATE_IDLE = 2'd0;
localparam [1:0] STATE_EXEC = 2'd1;
localparam [1:0] STATE_DONE = 2'd2;

localparam int MAX_M = 4;
localparam int MAX_N = 4;
localparam int MAX_K = 32;

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
logic [1023:0] tile_rd0_data_w;
logic [1023:0] tile_rd1_data_w;

logic        acc_rd_en_w;
logic [1:0]  acc_rd_reg_w;
logic [511:0] acc_rd_data_w;

logic        acc_wr_en_w;
logic [1:0]  acc_wr_reg_w;
logic [511:0] acc_wr_data_w;

logic [511:0] mac_c_acc_w;
logic         mac_sat_w;
logic         illegal_cfg_w;
logic         illegal_reg_class_w;
logic         illegal_op_w;
logic  [1:0]  ms1_idx_w;
logic  [1:0]  ms2_idx_w;
logic  [1:0]  md_idx_w;

assign illegal_cfg_w = (cfg_m_i > MAX_M) || (cfg_n_i > MAX_N) || (cfg_k_i > MAX_K);
assign illegal_reg_class_w = cmd_ms1_i[2] || cmd_ms2_i[2] || !cmd_md_i[2];
assign illegal_op_w = (cmd_op_i != 2'b00);
assign ms1_idx_w = ms1_q[1:0];
assign ms2_idx_w = ms2_q[1:0];
assign md_idx_w = md_q[1:0];

assign tile_rd0_en_w = (state_q == STATE_EXEC);
assign tile_rd1_en_w = (state_q == STATE_EXEC);
assign tile_rd0_reg_w = ms1_idx_w;
assign tile_rd1_reg_w = ms2_idx_w;

assign acc_rd_en_w = (state_q == STATE_EXEC);
assign acc_rd_reg_w = md_idx_w;

assign acc_wr_en_w = (state_q == STATE_EXEC) && !illegal_q;
assign acc_wr_reg_w = md_idx_w;
assign acc_wr_data_w = mac_c_acc_w;

assign cmd_ready_o = (state_q == STATE_IDLE);
assign busy_o = (state_q == STATE_EXEC);
assign done_valid_o = (state_q == STATE_DONE);
assign done_illegal_o = (state_q == STATE_DONE) && illegal_q;
assign done_pc_o = pc_q;

assign xmsat_set_valid_o = (state_q == STATE_DONE) && !illegal_q && sat_q;
assign xmsat_set_bits_o = sat_q;

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
                if (cmd_valid_i) begin
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
                sat_q <= mac_sat_w;
                state_q <= STATE_DONE;
            end
            STATE_DONE: begin
                state_q <= STATE_IDLE;
            end
            default: begin
                state_q <= STATE_IDLE;
            end
        endcase
    end
end

endmodule
