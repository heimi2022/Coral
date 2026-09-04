/*
矩阵乘法分块前端。

M 沿时间方向展开，N/K 沿阵列的列/行方向分块。当前支持 M、N、K <= 64，
每个维度最多切成两个 tile，因此最多生成四个 block：

    N0-K0, N0-K1, N1-K0, N1-K1

weight FIFO 和 act/psum FIFO 使用相同的 block 编号，保证两类描述一一对应。
*/

module matmul_tiling #(
    parameter int TILE_COLS = 32,
    parameter int TILE_ROWS = 32
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start_i,
    input  logic [31:0] cfg_m_i,
    input  logic [31:0] cfg_n_i,
    input  logic [31:0] cfg_k_i,
    input  logic [2:0]  rs1_i,
    input  logic [2:0]  rs2_i,
    input  logic [2:0]  rd_i,

    input  logic        weight_pop_i,
    output logic [2:0]  rs2_o,
    output logic [5:0]  weight_base_addr_o,
    output logic [$clog2(TILE_COLS + 1)-1:0] weight_n_rows_o,
    output logic [$clog2(TILE_ROWS + 1)-1:0] weight_k_rows_o,
    output logic        weight_col_o,
    output logic        weight_empty_o,

    input  logic        stream_pop_i,
    output logic [2:0]  rs1_o,
    output logic [2:0]  rd_o,
    output logic [$clog2(2 * TILE_ROWS)-1:0] act_base_row_o,
    output logic [$clog2(2 * TILE_ROWS + 1)-1:0] act_psum_m_rows_o,
    output logic [$clog2(TILE_ROWS + 1)-1:0] act_psum_k_rows_o,
    output logic [$clog2(TILE_COLS + 1)-1:0] act_psum_n_cols_o,
    output logic        act_col_o,
    output logic        act_psum_last_o,
    output logic        act_psum_empty_o,

    output logic        fill_busy_o
);

    localparam int ACT_PSUM_ADDR_WIDTH = $clog2(2 * TILE_ROWS);
    localparam int ROW_CNT_WIDTH = (TILE_ROWS <= 1) ? 1 : $clog2(TILE_ROWS + 1);
    localparam int COL_CNT_WIDTH = (TILE_COLS <= 1) ? 1 : $clog2(TILE_COLS + 1);
    localparam int M_CNT_WIDTH = $clog2(2 * TILE_ROWS + 1);

    // weight descriptor 固定为 22 bit：
    // [21:19] rs2：B 矩阵寄存器号。
    // [18:13] base_addr：当前 N block 的最后一行地址，pe_ctrl 从后向前读取。
    // [12:7]  n_rows：当前 N block 的有效行数。
    // [6:1]   k_rows：当前 K block 的有效行数。
    // [0]     col：ABMatrixReg 的半行选择，0=低 32B，1=高 32B。
    localparam int WEIGHT_DESC_WIDTH = 22;

    // act/psum descriptor 固定为 27 bit：
    // [26:24] rs1：A 矩阵寄存器号。
    // [23:21] rd：C/累加寄存器号。
    // [20:15] k_rows：当前 K block 的有效行数。
    // [14:8]  m_rows：M 方向的有效行数，7 bit 可表示 1~64。
    // [7:2]   n_cols：当前 N block 的有效列数。
    // [1]     col：ABMatrixReg 的半行选择，0=低 32B，1=高 32B。
    // [0]     last：是否为当前 matmul 命令的最后一个 block。
    localparam int ACT_PSUM_DESC_WIDTH = 27;

    typedef enum logic {StateIdle, StateFill} state_e;
    state_e state, next_state;

    logic cfg_k_gt32;
    logic cfg_n_gt32;
    // block 总数减一：0 表示 1 个 block，1 表示 2 个 block，3 表示 4 个 block。
    logic [1:0] fill_block_total;
    // 当前正在生成的 block 索引，范围为 0~3。
    logic [1:0] block_fill_count;
    logic block_queue_wr_en;

    logic fill_n_block_idx;
    logic fill_k_block_idx;
    logic [COL_CNT_WIDTH-1:0] fill_n_block_cols;
    logic [ROW_CNT_WIDTH-1:0] fill_k_block_rows;
    logic [ROW_CNT_WIDTH-1:0] fill_k_block_rows_first;
    logic [ROW_CNT_WIDTH-1:0] fill_k_block_rows_second;
    logic [COL_CNT_WIDTH-1:0] fill_n_block_cols_first;
    logic [COL_CNT_WIDTH-1:0] fill_n_block_cols_second;
    logic [4:0] fill_n_block_cols_m1; // 未参数化，此位宽需要 N = 32
    logic [M_CNT_WIDTH-1:0] fill_m_rows;
    logic [5:0] fill_weight_base_addr;
    logic fill_weight_col;
    logic fill_act_col;
    logic fill_block_last;

    logic [WEIGHT_DESC_WIDTH-1:0] weight_queue_wr_data;
    logic [WEIGHT_DESC_WIDTH-1:0] weight_queue_rd_data;
    logic [ACT_PSUM_DESC_WIDTH-1:0] act_psum_queue_wr_data;
    logic [ACT_PSUM_DESC_WIDTH-1:0] act_psum_queue_rd_data;

    assign cfg_k_gt32 = (cfg_k_i[5] && (|cfg_k_i[4:0])) || cfg_k_i[6];
    assign cfg_n_gt32 = (cfg_n_i[5] && (|cfg_n_i[4:0])) || cfg_n_i[6];

    // N 和 K 各自最多分成两个 block，因此编码后的总数减一为 0、1 或 3。
    assign fill_block_total = (cfg_k_gt32 && cfg_n_gt32) ? 2'd3 :
                              (cfg_k_gt32 || cfg_n_gt32) ? 2'd1 : 2'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            block_fill_count <= '0;
        end else if (start_i) begin
            block_fill_count <= '0;
        end else begin
            if (block_queue_wr_en)
                block_fill_count <= block_fill_count + 2'd1;
        end
    end

    // 第一个 block 取低 32 个元素；第二个 block 取剩余元素。
    // 软件需要保证 N/K 不超过 64 ！！！  否则下面逻辑有错
    assign fill_k_block_rows_first = cfg_k_gt32 ? ROW_CNT_WIDTH'(TILE_ROWS) :
                                                   ROW_CNT_WIDTH'(cfg_k_i);
    assign fill_k_block_rows_second = cfg_k_i[6] ? ROW_CNT_WIDTH'(TILE_ROWS) : cfg_k_i[4:0];
    assign fill_n_block_cols_first = cfg_n_gt32 ? COL_CNT_WIDTH'(TILE_COLS) :
                                                   COL_CNT_WIDTH'(cfg_n_i);
    assign fill_n_block_cols_second = cfg_n_i[6] ? COL_CNT_WIDTH'(TILE_COLS) : cfg_n_i[4:0];

    // 根据已经写入 FIFO 的 block 数决定当前 block 属于 N0/N1 和 K0/K1。
    // 四个 block 的固定顺序是：N0-K0、N0-K1、N1-K0、N1-K1。
    always @* begin
        fill_n_block_idx = 1'b0;
        fill_k_block_idx = 1'b0;
        if (cfg_k_gt32 && cfg_n_gt32) begin
            case (block_fill_count)
                2'd0: begin
                    fill_k_block_idx = 1'b0;
                    fill_n_block_idx = 1'b0;
                end
                2'd1: begin
                    fill_k_block_idx = 1'b1;
                    fill_n_block_idx = 1'b0;
                end
                2'd2: begin
                    fill_k_block_idx = 1'b0;
                    fill_n_block_idx = 1'b1;
                end
                2'd3: begin
                    fill_k_block_idx = 1'b1;
                    fill_n_block_idx = 1'b1;
                end
            endcase
        end else if (cfg_n_gt32) begin
            fill_n_block_idx = block_fill_count[0];
        end else if (cfg_k_gt32) begin
            fill_k_block_idx = block_fill_count[0];
        end
    end

    assign block_queue_wr_en = (state == StateFill);

// 右矩阵分块逻辑
    // A 和 B 的 K block 使用同一个 col：低 32B 对应 K0，高 32B 对应 K1。
    assign fill_weight_col = fill_k_block_idx;
    // 当前 block 在 N/K 方向的有效尺寸。
    assign fill_k_block_rows = fill_k_block_idx ? fill_k_block_rows_second : fill_k_block_rows_first;
    assign fill_n_block_cols = fill_n_block_idx ? fill_n_block_cols_second : fill_n_block_cols_first;

    // 从 AB Matrix 读数据的地址 0/32 + n 行数 - 1
    assign fill_n_block_cols_m1 = fill_n_block_cols - 6'd1;
    assign fill_weight_base_addr = {fill_n_block_idx, fill_n_block_cols_m1};

    always @* begin
        weight_queue_wr_data = '0;
        weight_queue_wr_data[0]    = fill_weight_col;
        weight_queue_wr_data[6:1]  = fill_k_block_rows;
        weight_queue_wr_data[12:7] = fill_n_block_cols;
        weight_queue_wr_data[18:13] = fill_weight_base_addr;
        weight_queue_wr_data[21:19] = rs2_i;
    end

    fifo #(
        .DATA_WIDTH (WEIGHT_DESC_WIDTH),
        .DEPTH (4)
    ) u_weight_block_fifo (
        .clk (clk),
        .rst_n (rst_n),
        .wr_en_i (block_queue_wr_en),
        .wr_data_i (weight_queue_wr_data),
        .full_o (),
        .rd_en_i (weight_pop_i),
        .rd_data_o (weight_queue_rd_data),
        .empty_o (weight_empty_o)
    );

    assign rs2_o = weight_queue_rd_data[21:19];
    assign weight_base_addr_o = weight_queue_rd_data[18:13];
    assign weight_n_rows_o = weight_queue_rd_data[12:7];
    assign weight_k_rows_o = weight_queue_rd_data[6:1];
    assign weight_col_o = weight_queue_rd_data[0];

// 左矩阵分块逻辑
    // 最后一个 block 用于通知输出侧和 MatrixCore 当前命令已经结束。
    // 当前计数等于“总数减一”时，当前写入的就是最后一个 block。
    assign fill_block_last = (block_fill_count == fill_block_total);
    assign fill_act_col = fill_k_block_idx;
    assign fill_m_rows = M_CNT_WIDTH'(cfg_m_i);
    // 当前阶段 psum 起始地址仍固定为 0，后续接入 C 分块写回时再扩展。
    always @* begin
        act_psum_queue_wr_data = '0;
        act_psum_queue_wr_data[20:15] = fill_k_block_rows;
        act_psum_queue_wr_data[14:8]  = fill_m_rows;
        act_psum_queue_wr_data[7:2]   = fill_n_block_cols;
        act_psum_queue_wr_data[1]     = fill_act_col;
        act_psum_queue_wr_data[0]     = fill_block_last;
        act_psum_queue_wr_data[23:21] = rd_i;
        act_psum_queue_wr_data[26:24] = rs1_i;
    end

    fifo #(
        .DATA_WIDTH (ACT_PSUM_DESC_WIDTH),
        .DEPTH (4)
    ) u_act_psum_block_fifo (
        .clk (clk),
        .rst_n (rst_n),
        .wr_en_i (block_queue_wr_en),
        .wr_data_i (act_psum_queue_wr_data),
        .full_o (),
        .rd_en_i (stream_pop_i),
        .rd_data_o (act_psum_queue_rd_data),
        .empty_o (act_psum_empty_o)
    );

    assign rs1_o = act_psum_queue_rd_data[26:24];
    assign rd_o = act_psum_queue_rd_data[23:21];
    assign act_base_row_o = '0;
    assign act_psum_k_rows_o = act_psum_queue_rd_data[20:15];
    assign act_psum_m_rows_o = act_psum_queue_rd_data[14:8];
    assign act_psum_n_cols_o = act_psum_queue_rd_data[7:2];
    assign act_col_o = act_psum_queue_rd_data[1];
    assign act_psum_last_o = act_psum_queue_rd_data[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= StateIdle;
        else
            state <= next_state;
    end

    always @* begin
        next_state = state;
        case (state)
            StateIdle: if (start_i) next_state = StateFill;
            StateFill: if (fill_block_last) next_state = StateIdle;
            default: next_state = StateIdle;
        endcase
    end

    assign fill_busy_o = (state == StateFill);

endmodule
