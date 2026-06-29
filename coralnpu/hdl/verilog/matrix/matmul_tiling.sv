/*
矩阵乘法分块前端

作用：
1. 接收 matmul 命令，并锁存当前命令的 m / n / k 配置。
2. 根据 m / n / k 生成 weight / act 两类任务队列。
3. weight 队列按“块”存，每块记录 rs2、倒序读取基地址和 k 大小。
4. act 队列按“块”存，每块记录 rs1、rd、act 起始行、m 大小、n 大小，以及是否为当前命令最后一块。
5. psum 不再单独建 FIFO，相关输出直接由 act 队头信息组合得到。

当前约束：
1. 暂时只支持 n <= 32，因此当前只处理单个 n tile。
2. k 最大按 64 处理，因此最多拆成两段，每段最多 32。
3. act 地址空间按两段处理：第一段从 0 开始，第二段从 TILE_ROWS 开始。
4. 当 k 需要拆成两段时，会压入两块 act 描述。
5. 是否允许接收新命令由外部控制，这里默认 `start_i` 已经是合法接收脉冲。
*/

module matmul_tiling #(
    parameter int TILE_COLS = 32,
    parameter int TILE_ROWS = 32
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic                                start_i,
    input  logic [31:0]                         cfg_m_i,
    input  logic [31:0]                         cfg_n_i,
    input  logic [31:0]                         cfg_k_i,
    input  logic [2:0]                          rs1_i,
    input  logic [2:0]                          rs2_i,
    input  logic [2:0]                          rd_i,

    input  logic                                weight_pop_i,
    output logic [2:0]                          rs2_o,
    output logic [5:0]                          weight_base_addr_o,
    output logic [$clog2(TILE_ROWS + 1)-1:0]    weight_k_rows_o,
    output logic                                weight_empty_o,

    input  logic                                stream_pop_i,
    output logic [2:0]                          rs1_o,
    output logic [2:0]                          rd_o,
    output logic [$clog2(2 * TILE_ROWS)-1:0]    act_base_row_o,
    output logic [$clog2(TILE_ROWS + 1)-1:0]    act_psum_m_rows_o,
    output logic [$clog2(TILE_COLS + 1)-1:0]    act_psum_n_cols_o,
    output logic                                act_psum_last_o,
    output logic                                act_psum_empty_o,
    output logic [$clog2(2 * TILE_ROWS)-1:0]    psum_base_row_o,

    output logic                                fill_busy_o
);

    localparam int ACT_PSUM_ADDR_WIDTH     = $clog2(2 * TILE_ROWS);
    localparam int ROW_CNT_WIDTH          = (TILE_ROWS <= 1) ? 1 : $clog2(TILE_ROWS + 1);
    localparam int COL_CNT_WIDTH          = (TILE_COLS <= 1) ? 1 : $clog2(TILE_COLS + 1);
    localparam int WEIGHT_DESC_WIDTH      = 3 + 6 + ROW_CNT_WIDTH;
    localparam int ACT_PSUM_DESC_WIDTH    = 3 + 3 + ACT_PSUM_ADDR_WIDTH + ROW_CNT_WIDTH + COL_CNT_WIDTH + 1;
    typedef enum logic {
        StateIdle,
        StateFill
    } state_e;

    state_e state, next_state;

    logic                         fill_has_two_k_chunks;
    logic [ROW_CNT_WIDTH-1:0]     fill_first_k_chunk_rows;
    logic [ROW_CNT_WIDTH-1:0]     fill_second_k_chunk_rows;
    logic [2:0]                   weight_queue_fill_total;
    logic [2:0]                   act_psum_queue_fill_total;
    logic [2:0]                   weight_queue_fill_count;
    logic [2:0]                   act_psum_queue_fill_count;
    logic                         weight_queue_fill_done;
    logic                         act_psum_queue_fill_done;
    logic                         all_queue_fill_done;
    logic                         weight_queue_wr_en;
    logic                         act_psum_queue_wr_en;
    logic [WEIGHT_DESC_WIDTH-1:0] weight_queue_wr_data;
    logic [WEIGHT_DESC_WIDTH-1:0] weight_queue_rd_data;
    logic [ACT_PSUM_DESC_WIDTH-1:0] act_psum_queue_wr_data;
    logic [ACT_PSUM_DESC_WIDTH-1:0] act_psum_queue_rd_data;
    logic [5:0]                   fill_first_weight_base_addr;
    logic [5:0]                   fill_second_weight_base_addr;

    assign fill_busy_o    = (state == StateFill);

// 当前填充命令的 K 是否需要拆成两段。
    assign fill_has_two_k_chunks = (cfg_k_i[5] && (|cfg_k_i[4:0])) || cfg_k_i[6];

    always @* begin
        if (cfg_k_i[5] | cfg_k_i[6])
            fill_first_k_chunk_rows = ROW_CNT_WIDTH'(TILE_ROWS);
        else
            fill_first_k_chunk_rows = ROW_CNT_WIDTH'(cfg_k_i[4:0]);
    end

    always @* begin
        if (cfg_k_i[6])
            fill_second_k_chunk_rows = ROW_CNT_WIDTH'(TILE_ROWS);
        else
            fill_second_k_chunk_rows = ROW_CNT_WIDTH'(cfg_k_i[4:0]);
    end

    assign all_queue_fill_done = weight_queue_fill_done && act_psum_queue_fill_done;



/* 权重解码 */
    // 当前正在填充的命令最多只需要两个 weight block。
    assign weight_queue_fill_total = fill_has_two_k_chunks ? 3'(2) : 3'(1);
    assign weight_queue_fill_done  = (weight_queue_fill_count == weight_queue_fill_total);
    assign weight_queue_wr_en      = (state == StateFill) && !weight_queue_fill_done;

    // weight 队列写入计数。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_queue_fill_count <= '0;
        end else if (start_i) begin
            weight_queue_fill_count <= '0;
        end else if (weight_queue_wr_en) begin
            weight_queue_fill_count <= weight_queue_fill_count + 3'(1);
        end
    end

    // weight 块的地址字段按倒序读取语义保存：
    // 1. 第 0 块保存 first_k_chunk_rows-1，表示从该块最后一行开始往回读
    // 2. 第 1 块保存 TILE_ROWS+second_k_chunk_rows-1，表示第二块最后一行地址
    assign fill_first_weight_base_addr  = 6'(fill_first_k_chunk_rows - ROW_CNT_WIDTH'(1));
    assign fill_second_weight_base_addr = 6'(TILE_ROWS) + 6'(fill_second_k_chunk_rows - ROW_CNT_WIDTH'(1));

    always @* begin
        if (weight_queue_fill_count == '0)
            weight_queue_wr_data = {rs2_i, fill_first_weight_base_addr, fill_first_k_chunk_rows};
        else
            weight_queue_wr_data = {rs2_i, fill_second_weight_base_addr, fill_second_k_chunk_rows};
    end

    fifo #(
        .DATA_WIDTH ( WEIGHT_DESC_WIDTH  ),
        .DEPTH      ( 4                  )
    ) u_weight_block_fifo (
        .clk       ( clk                  ),
        .rst_n     ( rst_n                ),
        .wr_en_i   ( weight_queue_wr_en   ),
        .wr_data_i ( weight_queue_wr_data ),
        .full_o    (                      ),
        .rd_en_i   ( weight_pop_i         ),
        .rd_data_o ( weight_queue_rd_data ),
        .empty_o   ( weight_empty_o       )
    );

    assign rs2_o              = weight_queue_rd_data[WEIGHT_DESC_WIDTH-1 -: 3];
    assign weight_base_addr_o = weight_queue_rd_data[ROW_CNT_WIDTH+5:ROW_CNT_WIDTH];
    assign weight_k_rows_o    = weight_queue_rd_data[ROW_CNT_WIDTH-1:0];

/* 激活/psum 解码 */
    // act_psum 队列按块存：
    // 1. 第 0 块从地址 0 开始
    // 2. 第 1 块从地址 TILE_ROWS 开始
    // 3. 每块都额外带上当前 tile 的 n 大小
    // 4. 最低位标记这是不是当前命令最后一块
    assign act_psum_queue_fill_total = fill_has_two_k_chunks ? 3'(2) : 3'(1);
    assign act_psum_queue_fill_done  = (act_psum_queue_fill_count == act_psum_queue_fill_total);
    assign act_psum_queue_wr_en      = (state == StateFill) && !act_psum_queue_fill_done;

    always @* begin
        if (act_psum_queue_fill_count == '0)
            act_psum_queue_wr_data = {rs1_i,
                                      rd_i,
                                      ACT_PSUM_ADDR_WIDTH'(0),
                                      ROW_CNT_WIDTH'(cfg_m_i),
                                      COL_CNT_WIDTH'(cfg_n_i),
                                      !fill_has_two_k_chunks};
        else
            act_psum_queue_wr_data = {rs1_i,
                                      rd_i,
                                      ACT_PSUM_ADDR_WIDTH'(TILE_ROWS),
                                      ROW_CNT_WIDTH'(cfg_m_i),
                                      COL_CNT_WIDTH'(cfg_n_i),
                                      1'b1};
    end

    // act_psum 队列写入计数。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_psum_queue_fill_count <= '0;
        end else if (start_i) begin
            act_psum_queue_fill_count <= '0;
        end else if (act_psum_queue_wr_en) begin
            act_psum_queue_fill_count <= act_psum_queue_fill_count + 3'(1);
        end
    end

    fifo #(
        .DATA_WIDTH ( ACT_PSUM_DESC_WIDTH  ),
        .DEPTH      ( 4                    )
    ) u_act_psum_block_fifo (
        .clk       ( clk                  ),
        .rst_n     ( rst_n                ),
        .wr_en_i   ( act_psum_queue_wr_en ),
        .wr_data_i ( act_psum_queue_wr_data ),
        .full_o    (),
        .rd_en_i   ( stream_pop_i         ),
        .rd_data_o ( act_psum_queue_rd_data ),
        .empty_o   ( act_psum_empty_o     )
    );

    assign rs1_o              = act_psum_queue_rd_data[ACT_PSUM_DESC_WIDTH-1 -: 3];
    assign rd_o               = act_psum_queue_rd_data[ACT_PSUM_DESC_WIDTH-4 -: 3];
    assign act_base_row_o     = act_psum_queue_rd_data[ACT_PSUM_ADDR_WIDTH+ROW_CNT_WIDTH+COL_CNT_WIDTH :
                                                        ROW_CNT_WIDTH+COL_CNT_WIDTH+1];
    assign act_psum_m_rows_o  = act_psum_queue_rd_data[ROW_CNT_WIDTH+COL_CNT_WIDTH:COL_CNT_WIDTH+1];
    assign act_psum_n_cols_o  = act_psum_queue_rd_data[COL_CNT_WIDTH:1];
    assign act_psum_last_o    = act_psum_queue_rd_data[0];

    // psum 不再单独缓存，直接复用 act 队头对应的 tile 信息。
    assign psum_base_row_o   = ACT_PSUM_ADDR_WIDTH'(0);

// 状态机
    // 状态寄存器。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= StateIdle;
        else
            state <= next_state;
    end

    // 次态逻辑。
    always @* begin
        next_state = state;

        case (state)
            StateIdle: begin
                if (start_i)
                    next_state = StateFill;
            end

            StateFill: begin
                if (all_queue_fill_done)
                    next_state = StateIdle;
            end

            default: begin
                next_state = StateIdle;
            end
        endcase
    end

endmodule
