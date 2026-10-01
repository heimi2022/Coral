/*
TILE_ROWS 必须 >= 3，否则输出 valid 延迟移位的索引需要单独处理。
当前支持 M、N、K <= 64；N/K 维度由 matmul_tiling 拆成最多四个 block。
外部矩阵寄存器对此模块保持最高优先级，故暂不设计握手逻辑

PE 控制模块

当前版本的控制思路：
1. `matmul_tiling` 负责把一条 matmul 命令拆成 weight block 和 act/psum block 两类队列。
2. `pe_ctrl` 在真正进入某个 block 前，先把队头描述 pop 出来并锁存，后续整块执行只使用本地寄存器。
3. `LoadWeight` 负责纯装权重，`Stream` 负责纯计算，`StreamPreloadWeight` 负责一边计算当前块一边预装下一块权重。
4. 输出侧单独维护一条 metadata FIFO，记录每个输出 block 对应的 m / n / rd / last，并在 `psum_valid` 拉起时切到写回路径。
5. 深度为 2 的 PC FIFO 保存已接收命令，最终写回后经完成握手出队；最多两条在途。
6. 尽管 C reg 做了奇偶bank设计, 但是当矩阵乘负载的 M 为偶数时(且M 大于28 左右)，仍然会出现 tile 边界的 bank 冲突。
    为避免冲突，在 tile 边界插入一个 bubble，暂停新的 rs1 读取，但不影响前一个 tile 已经进入阵列的数据。
    wjj 2026-09 decode 时,为带宽受限,bubble带来的延迟会完全被 weight block 的装载时间覆盖,因此不影响吞吐。
                prefill 时, m 一般很大 , bubble 对吞吐影响也可以忽略。

默认假设：
1. rs2_data_i 每拍提供一行权重，直接送到 pe_array 的 `weight_tile`。
2. rs1_data_i 每拍提供一拍激活向量，直接送到 pe_array 的 `act_top`。
3. rd_data_i 用来提供历史 psum / C 向量，在阵列尾部和 `psum_bottom` 做累加。
4. k 维最大按 64 处理，因此最多拆成两段，每段最多 32 行。
5. 当前输出写回路径已经接入 `rd_read_o / rd_addr_o / rd_write_valid_o`，但仍然没有和外部做完整 ready/ack 协议。

后面真接系统时，可以再把下面几件事细化：
1. rs1/rs2/rd 的 ready/valid 协议
2. 输出写回和外部 SRAM / buffer 的握手
3. n > 32、多 tile 串行等更完整的尾块处理
4. C reg 标志位为0时，PE阵列结果可以直接bypass到C reg 少几次 累加器的翻转


只在脉动阵列最底部做了 MX 量化逻辑，由于目前MX量化分组为32个元素一组，脉动阵列大小刚好为32*32，因此这是正确的。
后续若分组数改变，或者脉动阵列一次能容纳的K变大了(量化位宽导致等),这里逻辑需要修改
*/

module pe_ctrl #(
    parameter int MAX_ELEM_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,
    parameter int TILE_COLS  = 32,
    parameter int TILE_ROWS  = 32
) (
    input  logic                                        clk                         ,
    input  logic                                        rst_n                       ,

    // matmul command input
    input  logic [31:0]                                 cfg_m_i                     ,
    input  logic [31:0]                                 cfg_n_i                     ,
    input  logic [31:0]                                 cfg_k_i                     ,
    input  logic [2:0]                                  rs1_i                       ,
    input  logic [2:0]                                  rs2_i                       ,
    input  logic [2:0]                                  rd_i                        ,
    input  logic                                        cmd_valid_i                 ,
    input  logic [31:0]                                 cmd_pc_i                    ,
    output logic                                        cmd_ready_o                 ,
    output logic                                        busy_o                      ,
    output logic                                        done_valid_o                ,
    input  logic                                        done_ready_i                ,
    output logic [31:0]                                 done_pc_o                   ,

    input  logic [TILE_COLS * MAX_ELEM_WIDTH - 1 : 0]   rs1_data_i                  ,
    input  logic                                        rs1_data_valid_i            ,
    output logic [2:0]                                  rs1_o                       ,
    output logic [5:0]                                  rs1_addr_o                  ,
    output logic                                        rs1_col_o                   ,
    output logic                                        rs1_read_valid_o            ,
    input  logic [255:0]                                rs1_scale_data_i            ,
    input  logic                                        rs1_scale_data_valid_i      ,
    output logic [1:0]                                  rs1_scale_reg_o             ,
    output logic                                        rs1_scale_bank_o            ,
    output logic                                        rs1_scale_kblock_o          ,
    output logic                                        rs1_scale_read_valid_o      ,

    input  logic [TILE_ROWS * MAX_ELEM_WIDTH - 1 : 0]   rs2_data_i                  ,
    input  logic                                        rs2_data_valid_i            ,
    output logic [2:0]                                  rs2_o                       ,
    output logic [5:0]                                  rs2_addr_o                  ,
    output logic                                        rs2_col_o                   ,
    output logic                                        rs2_read_valid_o            ,
    input  logic [255:0]                                rs2_scale_data_i            ,
    input  logic                                        rs2_scale_data_valid_i      ,
    output logic [1:0]                                  rs2_scale_reg_o             ,
    output logic                                        rs2_scale_bank_o            ,
    output logic                                        rs2_scale_kblock_o          ,
    output logic                                        rs2_scale_read_valid_o      ,

    input  logic [TILE_COLS * ACC_WIDTH - 1 : 0]        rd_data_i                   ,
    input  logic                                        rd_data_valid_i             ,
    input  logic [3:0]                                  c_reg_zero_n_i              ,
    output logic                                        c_reg_zero_release_valid_o  ,
    output logic [3:0]                                  c_reg_zero_release_mask_o   ,
    output logic [2:0]                                  rd_read_o                   ,
    output logic [5:0]                                  rd_read_addr_o              ,
    output logic                                        rd_read_nblock_o            ,
    output logic                                        rd_read_valid_o             ,

    output logic [2:0]                                  rd_write_o                  ,
    output logic [5:0]                                  rd_write_addr_o             ,
    output logic                                        rd_write_nblock_o           ,
    output logic                                        rd_write_valid_o            ,
    output logic [TILE_COLS * ACC_WIDTH - 1 : 0]        pe_array_o                  ,

    output logic                                        cmd_busy_o                  ,
    output logic                                        matmul_finish_o              

);

    localparam int ACT_ADDR_WIDTH         = $clog2(2 * TILE_ROWS);
    localparam int ROW_CNT_WIDTH          = (TILE_ROWS <= 1) ? 1 : $clog2(TILE_ROWS + 1);
    localparam int M_CNT_WIDTH            = $clog2(2 * TILE_ROWS + 1);
    localparam int COL_CNT_WIDTH          = (TILE_COLS <= 1) ? 1 : $clog2(TILE_COLS + 1);
    // 输出 metadata 保存 N block、M/N 尺寸、A scale reg、K block、rd 和 last。
    localparam int OUTPUT_META_WIDTH      = M_CNT_WIDTH + COL_CNT_WIDTH + 2 + 1 + 3 + 1 + 1;
    // B scale metadata 只保存 reg、N bank 和 K block。
    localparam int B_SCALE_META_WIDTH     = 4;
    // 写回 metadata 按 block 保存 M、N、C reg 和 K block。
    localparam int WRITEBACK_META_WIDTH   = M_CNT_WIDTH + COL_CNT_WIDTH + 3 + 1 + 1;
    localparam int PE_ACC_WIDTH           = 2 * MAX_ELEM_WIDTH + $clog2(TILE_ROWS);  //  等于 2*8+5=21
    localparam int ACCUM_PIPE_STAGES      = 4;
    // block-head 在该位置有效时，下一拍将出现该 block 的首个累加结果。
    localparam int WRITEBACK_META_POP_INDEX = TILE_ROWS + ACCUM_PIPE_STAGES - 1;

    typedef enum logic [2:0] {
        Idle,
        LoadWeight,
        StreamPreloadWeight,
        Stream
    } state_e;

    state_e state, next_state;

    logic [COL_CNT_WIDTH-1:0]                   active_n_cols;
    logic [ROW_CNT_WIDTH-1:0]                   active_k_cols;
    logic [2:0]                                 weight_rs2;
    logic [5:0]                                 weight_base_addr;
    logic                                       weight_col;
    logic [COL_CNT_WIDTH-1:0]                   weight_n_rows;
    logic [ROW_CNT_WIDTH-1:0]                   weight_k_cols;
    logic [2:0]                                 stream_rs1;
    logic [2:0]                                 stream_rd;
    logic [ACT_ADDR_WIDTH-1:0]                  stream_act_base_row;
    logic                                       stream_act_col;
    // M 可以取到 64，需要 7 位保存 64 这个计数终值。
    logic [M_CNT_WIDTH-1:0]                     stream_m_rows;

    logic [COL_CNT_WIDTH-1:0]                   weight_count;
    logic [M_CNT_WIDTH-1:0]                     stream_count;
    logic                                       load_weight_ping;
    logic                                       load_weight_pong;
    logic                                       weight_bank_sel;
    logic [TILE_COLS-1:0]                       act_return_col_mask_q;
    logic [TILE_ROWS-1:0]                       act_return_row_mask_q;
    logic [TILE_ROWS * MAX_ELEM_WIDTH - 1 : 0]  weight_tile;
    logic [TILE_COLS-1:0]                       psum_top_valid;
    logic [TILE_COLS-1:0]                       act_top_valid;
    logic [TILE_COLS * MAX_ELEM_WIDTH - 1 : 0]  act_top;
    logic [TILE_COLS-1:0]                       col_valid_mask;
    logic [TILE_ROWS-1:0]                       row_valid_mask;
    logic [TILE_COLS-1:0]                       output_col_valid_mask;
    logic                                       psum_valid;
    logic                                       psum_pre_valid;
    logic                                       psum_pre2_valid;
    logic [TILE_COLS * PE_ACC_WIDTH - 1 : 0]    psum_bottom;
    logic [TILE_COLS * ACC_WIDTH - 1 : 0]       accum_sum_o;
    logic                                       accum_valid;

    logic                                       weight_load_bank_sel;
    logic                                       weight_load_active;
    logic                                       stream_active;
    logic                                       stream_issue_active;
    logic                                       stream_boundary_bubble_q;
    logic                                       weight_read_last;
    logic                                       weight_write_last;
    logic                                       stream_last;
    logic                                       stream_last_q;
    logic                                       stream_start_pending_q;
    logic [2:0]                                 stream_start_age_q;
    logic                                       next_stream_ready;
    logic                                       weight_overlap_done;
    logic                                       stream_overlap_done;
    logic                                       weight_done_now;
    logic                                       stream_done_now;
    logic [1:0]                                 weight_banks_busy_q;
    logic                                       stream_bank_release;
    logic                                       weight_bank_available;
    logic                                       weight_load_ongoing_q;
    logic                                       weight_load_start;
    logic                                       cmd_accept;
    logic                                       cmd_retire;
    logic                                       enter_load_weight;
    logic                                       enter_stream;
    logic                                       weight_pop;
    logic                                       stream_pop;
    logic                                       start_stream_preload;
    logic                                       output_meta_push;
    logic                                       output_meta_pop;
    logic [OUTPUT_META_WIDTH-1:0]               output_meta_wr_data;
    logic [OUTPUT_META_WIDTH-1:0]               output_meta_rd_data;
    logic                                       writeback_meta_push;
    logic                                       writeback_meta_pop;
    logic [WRITEBACK_META_WIDTH-1:0]            writeback_meta_wr_data;
    logic [WRITEBACK_META_WIDTH-1:0]            writeback_meta_rd_data;
    logic                                       writeback_meta_empty;
    logic [M_CNT_WIDTH-1:0]                     writeback_head_m_rows;
    logic [COL_CNT_WIDTH-1:0]                   writeback_head_n_cols;
    logic [2:0]                                 writeback_head_rd;
    logic                                       writeback_head_nblock;
    logic [B_SCALE_META_WIDTH-1:0]              b_scale_meta_wr_data;
    logic [B_SCALE_META_WIDTH-1:0]              b_scale_meta_rd_data;
    logic                                       b_scale_meta_empty;
    logic                                       b_scale_meta_pop;
    logic [1:0]                                 output_rs1;
    logic [1:0]                                 rd_read_rs1;
    logic                                       a_scale_bank0_req;
    logic                                       a_scale_bank1_req;
    logic [M_CNT_WIDTH-1:0]                     output_cfg_m;
    logic [COL_CNT_WIDTH-1:0]                   output_cfg_n;
    logic                                       output_kblock;
    logic                                       output_nblock;
    logic                                       tiling_act_nblock;
    logic                                       rd_read_nblock;
    logic                                       rd_read_last;
    logic                                       writeback_head_last;
    logic                                       rd_write_last;
    logic [2:0]                                 output_rd;
    logic                                       output_last;
    logic [M_CNT_WIDTH-1:0]                     rd_read_m_rows;
    logic                                       rs1_scale_kblock_q;
    logic [2:0]                                 rd_read_sel;
    logic                                       rd_zero_block_q;
    logic                                       rd_zero_return_q;
    logic [TILE_COLS * ACC_WIDTH - 1 : 0]       accum_c_data;
    logic [M_CNT_WIDTH-1:0]                     rd_write_m_rows;
    logic [COL_CNT_WIDTH-1:0]                   rd_write_n_cols;
    logic                                       rd_write_nblock;
    logic [2:0]                                 rd_write_sel;
    logic                                       matmul_finish;
    logic [M_CNT_WIDTH-1:0]                     rd_read_count;
    logic [M_CNT_WIDTH-1:0]                     rd_read_count_p1;
    logic [M_CNT_WIDTH-1:0]                     rd_write_count;
    logic [M_CNT_WIDTH-1:0]                     rd_write_count_p1;
    logic                                       output_block_head_in;
    logic [TILE_ROWS + ACCUM_PIPE_STAGES - 1:0] output_block_head_shift;
    logic [COL_CNT_WIDTH-1:0]                   weight_count_p1;
    logic [M_CNT_WIDTH-1:0]                     stream_count_p1;
    logic [2:0]                                 tiling_rs1;
    logic [2:0]                                 tiling_rs2;
    logic [2:0]                                 tiling_rd;
    logic [5:0]                                 tiling_weight_base_addr;
    logic [COL_CNT_WIDTH-1:0]                   tiling_weight_n_rows;
    logic [ROW_CNT_WIDTH-1:0]                   tiling_weight_k_cols;
    logic                                       tiling_weight_col;
    logic                                       tiling_weight_empty;
    logic [ACT_ADDR_WIDTH-1:0]                  tiling_act_base_row;
    logic                                       tiling_act_col;
    logic [COL_CNT_WIDTH-1:0]                   tiling_psum_n_cols;
    logic [ROW_CNT_WIDTH-1:0]                   tiling_act_k_cols;
    logic [M_CNT_WIDTH-1:0]                     tiling_act_psum_m_rows;
    logic                                       tiling_act_psum_last;
    logic                                       tiling_act_psum_empty;
    logic                                       cmd_decode_busy;

    logic pc_full, pc_empty;
    logic tiling_start_q;
    logic [31:0] cfg_m_q, cfg_n_q, cfg_k_q;
    logic [2:0] rs1_q, rs2_q, rd_q;
    logic [1:0] completed_count_q;
    logic cmd_writeback_done;

    // 两条命令包含执行中和等待完成返回的命令；PC 一直保留到完成握手。
    // 上游解码保证接收的计算命令合法。
    assign cmd_ready_o = !pc_full && !cmd_decode_busy && !tiling_start_q;
    assign cmd_accept = cmd_valid_i && cmd_ready_o;
    assign cmd_retire = done_valid_o && done_ready_i;
    assign busy_o = !pc_empty;
    assign done_valid_o = !pc_empty && (completed_count_q != 0);

    fifo #(
        .DATA_WIDTH(32), 
        .DEPTH(3)
    ) u_matmul_pc_fifo (
        .clk(clk), 
        .rst_n(rst_n),
        .wr_en_i(cmd_accept), 
        .wr_data_i(cmd_pc_i),
        .full_o(pc_full), 
        .rd_en_i(cmd_retire),
        .rd_data_o(done_pc_o), 
        .empty_o(pc_empty)
    );

    // 最后一个 block 的最后一行写回计为完成；DMA 反压时可累计两次完成。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            completed_count_q <= '0;
        else begin
            case ({cmd_writeback_done, cmd_retire})
                2'b10: completed_count_q <= completed_count_q + 1'b1;
                2'b01: completed_count_q <= completed_count_q - 1'b1;
                default: begin end
            endcase
        end
    end

    // 分块生成跨多个周期，握手后外部参数允许立即变化。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_m_q <= '0; 
            cfg_n_q <= '0; 
            cfg_k_q <= '0;
            rs1_q <= '0; 
            rs2_q <= '0; 
            rd_q <= '0;
        end else if (cmd_accept) begin
            cfg_m_q <= cfg_m_i;
            cfg_n_q <= cfg_n_i;
            cfg_k_q <= cfg_k_i;
            rs1_q <= rs1_i;
            rs2_q <= rs2_i;
            rd_q <= rd_i;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tiling_start_q <= 1'b0;
        end else begin
            tiling_start_q <= cmd_accept;
        end
    end
    
    // 用分块前端生成 weight / act_psum 两类块描述。
    matmul_tiling #(
        .TILE_COLS ( TILE_COLS ),
        .TILE_ROWS ( TILE_ROWS )
    ) u_matmul_tiling (
        .clk               ( clk                         ),
        .rst_n             ( rst_n                       ),
        .start_i           ( tiling_start_q              ),
        .cfg_m_i           ( cfg_m_q                     ),
        .cfg_n_i           ( cfg_n_q                     ),
        .cfg_k_i           ( cfg_k_q                     ),
        .rs1_i             ( rs1_q                       ),
        .rs2_i             ( rs2_q                       ),
        .rd_i              ( rd_q                        ),
        .weight_pop_i      ( weight_pop                  ),
        .rs2_o             ( tiling_rs2                  ),
        .weight_base_addr_o( tiling_weight_base_addr     ),
        .weight_n_rows_o   ( tiling_weight_n_rows        ),
        .weight_k_cols_o   ( tiling_weight_k_cols        ),
        .weight_col_o      ( tiling_weight_col           ),
        .weight_empty_o    ( tiling_weight_empty         ),
        .stream_pop_i      ( stream_pop                  ),
        .rs1_o             ( tiling_rs1                  ),
        .rd_o              ( tiling_rd                   ),
        .act_base_row_o    ( tiling_act_base_row         ),
        .act_psum_m_rows_o ( tiling_act_psum_m_rows      ),
        .act_k_cols_o      ( tiling_act_k_cols            ),
        .psum_n_cols_o     ( tiling_psum_n_cols           ),
        .act_col_o         ( tiling_act_col              ),
        .act_nblock_o      ( tiling_act_nblock           ),
        .act_psum_last_o   ( tiling_act_psum_last        ),
        .act_psum_empty_o  ( tiling_act_psum_empty       ),
        .fill_busy_o       ( cmd_decode_busy             )
    );

    // 开始一个新 act/psum block 时，同样先锁存队头描述。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stream_rs1          <= '0;
            stream_rd           <= '0;
            stream_act_base_row <= '0;
            stream_act_col      <= '0;
            stream_m_rows       <= '0;
            active_n_cols       <= '0;
            active_k_cols       <= '0;
        end else if (stream_pop) begin
            stream_rs1          <= tiling_rs1;
            stream_rd           <= tiling_rd;
            stream_act_base_row <= tiling_act_base_row;
            stream_m_rows       <= tiling_act_psum_m_rows;
            stream_act_col      <= tiling_act_col;
            active_n_cols       <= tiling_psum_n_cols;
            active_k_cols       <= tiling_act_k_cols;
        end
    end

    // 开始一个新 weight block 时，先把队头描述锁存下来，后面整块都使用本地寄存器。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_rs2       <= '0;
            weight_base_addr <= '0;
            weight_col       <= '0;
            weight_n_rows    <= '0;
            weight_k_cols    <= '0;
        end else if (weight_pop) begin
            weight_rs2       <= tiling_rs2;
            weight_base_addr <= tiling_weight_base_addr;
            weight_col       <= tiling_weight_col;  // 需要高32B 还是低32B
            weight_n_rows    <= tiling_weight_n_rows;
            weight_k_cols    <= tiling_weight_k_cols;
        end
    end

    // `StreamPreloadWeight` 表示当前块计算和下一块装权同时进行。
    // 开始计算当前 block，同时预装载下一个 weight block
    assign start_stream_preload = (((state == LoadWeight) && weight_done_now && !tiling_weight_empty) ||
                                  ((state == StreamPreloadWeight) && stream_done_now && weight_done_now &&
                                   !tiling_weight_empty));

    assign weight_bank_available = weight_banks_busy_q < 2;
    assign weight_load_start = weight_load_active && !weight_load_ongoing_q;
    assign stream_bank_release = psum_pre_valid && (rd_read_count_p1 == rd_read_m_rows);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_banks_busy_q <= '0;
        end else begin
            case ({weight_load_start, stream_bank_release})
                2'b10: weight_banks_busy_q <= weight_banks_busy_q + 1'b1;
                2'b01: weight_banks_busy_q <= weight_banks_busy_q - 1'b1;
                default: ;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_load_ongoing_q <= 1'b0;
        end else begin
            if (weight_load_active)
                weight_load_ongoing_q <= !weight_read_last;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stream_overlap_done <= 1'b0;
            weight_overlap_done <= 1'b0;
        end else if (start_stream_preload || enter_load_weight) begin
            stream_overlap_done <= 1'b0;
            weight_overlap_done <= 1'b0;
        end else begin
            if (stream_last)
                stream_overlap_done <= 1'b1;
            if (weight_load_active && weight_read_last)
                weight_overlap_done <= 1'b1;
        end
    end

    assign weight_done_now = weight_overlap_done || (weight_load_active && weight_read_last);
    assign stream_done_now = stream_overlap_done || stream_last;

    assign weight_load_active = (((state == LoadWeight) || (state == StreamPreloadWeight)) &&
                                 !weight_overlap_done &&
                                 (weight_load_ongoing_q || weight_bank_available));

    assign enter_load_weight = ((state == Idle) && !tiling_weight_empty) ||
                               ((state == Stream) && stream_last && !tiling_weight_empty);

    assign weight_pop = enter_load_weight || start_stream_preload;

    assign enter_stream = (((state == LoadWeight) && weight_done_now && tiling_weight_empty) ||
                          ((state == StreamPreloadWeight) && stream_done_now && weight_done_now &&
                           tiling_weight_empty));

    assign stream_pop = enter_stream || start_stream_preload;

    assign cmd_busy_o = !cmd_ready_o;


/* 权重读取 */
    assign weight_count_p1 = weight_count + 1'd1;
    assign weight_read_last = (weight_count_p1 == weight_n_rows);

    // 权重行计数器：一块权重里每收到一行加一，到最后一行自动回零。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_count <= '0;
        end else if (weight_load_active) begin
            if (weight_read_last)
                weight_count <= '0;
            else
                weight_count <= weight_count_p1;
        end
    end

    // 同步 SRAM 的最后一行数据在最后一个读请求后一拍返回，
    // 因此 bank 选择要等这个延迟周期后再翻转。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            weight_write_last <= 1'b0;
        else
            weight_write_last <= weight_load_active && weight_read_last;
    end

    always @* begin
        rs2_o            = weight_rs2;
        rs2_addr_o       = weight_base_addr - 6'(weight_count);   // 后续一次读出多行右矩阵，需对此做修改
        rs2_col_o        = weight_col;
        rs2_read_valid_o = weight_load_active;
    end

/* 权重输入 */
    assign weight_tile   = rs2_data_i;
    // weight_load_bank_sel=0 表示当前把权重装到 ping，=1 表示装到 pong。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_load_bank_sel <= 1'b0;
        end else if (weight_write_last) begin
            weight_load_bank_sel <= ~weight_load_bank_sel;
        end else begin
            weight_load_bank_sel <= weight_load_bank_sel;
        end
    end

    // The final SRAM response can arrive after the request state has changed.
    assign load_weight_ping = !weight_load_bank_sel && rs2_data_valid_i;
    assign load_weight_pong =  weight_load_bank_sel && rs2_data_valid_i;

/* 激活读取 */
    // C Reg 为单端口 SRAM 时，m 为奇数会导致相邻 tile 的边界出现
    // “上一 tile 写偶数行、下一 tile 读偶数行”的冲突。
    // 在下一 tile 的首个激活读请求前插入一个周期的 bubble，
    // 只暂停新的 rs1 读取，不影响前一个 tile 已经进入阵列的数据。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stream_boundary_bubble_q <= 1'b0;
        end else begin
            if (stream_pop && stream_last && stream_m_rows[0]) begin
                stream_boundary_bubble_q <= 1'b1;
            end else if (stream_boundary_bubble_q) begin
                stream_boundary_bubble_q <= 1'b0;
            end
        end
    end

    assign stream_count_p1      = stream_count + 1'd1;
    assign stream_issue_active  = stream_active && !stream_boundary_bubble_q &&
                                  (!stream_start_pending_q || next_stream_ready);
    assign stream_last          = stream_issue_active &&
                                   (stream_count_p1 == stream_m_rows);

    // 当 m,n 太小, 会发生 前半段结果未写回 C reg，后半段就开始读 C reg 的情况, 故在此处设置一个 6 clk 的阈值
    assign next_stream_ready = (stream_start_age_q == 3'd7);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            stream_start_age_q <= 3'd0;
        else if (stream_issue_active && (stream_count == '0))
            stream_start_age_q <= 3'd0;
        else if (!next_stream_ready)
            stream_start_age_q <= stream_start_age_q + 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            stream_start_pending_q <= 1'b0;
        else if (stream_pop && !next_stream_ready)
            stream_start_pending_q <= 1'b1;
        else if (stream_issue_active)
            stream_start_pending_q <= 1'b0;
    end

    // rs1 SRAM has one cycle of read latency. The last request is therefore
    // delayed to the cycle in which the last activation row enters the PE.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            stream_last_q <= 1'b0;
        else
            stream_last_q <= stream_last;
    end

    // act/psum 行计数：一块计算里每消费一行加一，到最后一行自动回零。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stream_count <= '0;
        end else if (stream_issue_active) begin
            if (stream_last)
                stream_count <= '0;
            else
                stream_count <= stream_count_p1;
        end
    end
    
    assign stream_active = (state == Stream) || ((state == StreamPreloadWeight) && !stream_overlap_done);

    // rs1 相关控制单独处理。
    always @* begin
        rs1_o            = stream_rs1;
        rs1_addr_o       = stream_act_base_row + ACT_ADDR_WIDTH'(stream_count);
        rs1_col_o        = stream_act_col;
        rs1_read_valid_o = stream_issue_active;
    end

/* 激活输入 & 输出累加预取触发 */
    // Carry request metadata through the same one-cycle latency as SRAM data.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_return_col_mask_q <= '0;
            act_return_row_mask_q <= '0;
        end else if (rs1_read_valid_o) begin
            act_return_col_mask_q <= col_valid_mask;
            act_return_row_mask_q <= row_valid_mask;
        end
    end
    assign act_top_valid  = {TILE_COLS{rs1_data_valid_i}} & act_return_row_mask_q;
    assign psum_top_valid = {TILE_COLS{rs1_data_valid_i}} & act_return_col_mask_q;

    assign act_top          = rs1_data_i;

    // 输入侧列掩码：按当前正在计算的 block 的 n 生成，超出有效列的 PE 不参与本轮计算。
    always @* begin : gen_input_mask
        integer col_mask_idx;
        integer row_mask_idx;

        col_valid_mask = '0;
        for (col_mask_idx = 0; col_mask_idx < TILE_COLS; col_mask_idx = col_mask_idx + 1) begin
            if (col_mask_idx < active_n_cols)
                col_valid_mask[col_mask_idx] = 1'b1;
        end

        row_valid_mask = '0;
        for (row_mask_idx = 0; row_mask_idx < TILE_ROWS; row_mask_idx = row_mask_idx + 1) begin
            if (row_mask_idx < active_k_cols)
                row_valid_mask[row_mask_idx] = 1'b1;
        end
    end    

/* 计算 bank 选择 */ 
    // weight_bank_sel=0 表示当前计算使用 ping bank，=1 表示当前计算使用 pong bank。
    // 这里按 K<=64 处理，因此最多只会有两段 K。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_bank_sel <= 1'b0;
        end else if (stream_last_q) begin
            weight_bank_sel <= ~weight_bank_sel;
        end else begin
            weight_bank_sel <= weight_bank_sel;
        end
    end

    pe_array #(
        .MAX_ELEM_WIDTH ( MAX_ELEM_WIDTH ),
        .PE_ACC_WIDTH   ( PE_ACC_WIDTH  ),   
        .TILE_COLS      ( TILE_COLS  ),
        .TILE_ROWS      ( TILE_ROWS  )
    ) u_pe_array (
        .clk                    ( clk                ),
        .rst_n                  ( rst_n              ),
        .load_weight_ping_i     ( load_weight_ping  ),
        .load_weight_pong_i     ( load_weight_pong  ),
        .weight_bank_sel_i      ( {TILE_COLS{weight_bank_sel}} ),
        .weight_tile_i          ( weight_tile           ),
        .psum_top_valid_i       ( psum_top_valid   ),
        .act_top_valid_i        ( act_top_valid    ),
        .act_top_i              ( act_top          ),
        .psum_valid_o           ( psum_valid       ),
        .psum_pre_valid_o       ( psum_pre_valid   ),
        .psum_pre2_valid_o      ( psum_pre2_valid),
        .psum_bottom_o          ( psum_bottom      )
    );

    assign output_block_head_in = rs1_read_valid_o && (stream_count == '0);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            output_block_head_shift <= '0;
        end else begin
            output_block_head_shift <= {output_block_head_shift[TILE_ROWS + ACCUM_PIPE_STAGES - 2:0], output_block_head_in};
        end
    end

/* 累加 block metadata */
    // 这里按计算 block 粒度缓存一份 m / n / kblock / rd / last。
    // act_psum 队列每弹出一块，就向累加 block FIFO 压一条记录；
    // 输入侧第一个请求 beat 会打一发 block-head token，
    // 经过 TILE_ROWS 级移位后与输出 pre-valid 对齐，再把队头 metadata 读出来。
    assign output_meta_push    = stream_pop;
    assign output_meta_pop     = output_block_head_shift[TILE_ROWS-2];  // pre2_valid
    assign output_meta_wr_data = {tiling_act_nblock, tiling_act_psum_m_rows, tiling_psum_n_cols,
                                  tiling_rs1[1:0], tiling_act_col, tiling_rd, tiling_act_psum_last};

    fifo #(
        .DATA_WIDTH ( OUTPUT_META_WIDTH ),
        .DEPTH      ( 8                 )
    ) u_accum_block_meta_fifo (
        .clk       ( clk                 ),
        .rst_n     ( rst_n               ),
        .wr_en_i   ( output_meta_push    ),
        .wr_data_i ( output_meta_wr_data ),
        .full_o    (),
        .rd_en_i   ( output_meta_pop     ),
        .rd_data_o ( output_meta_rd_data ),
        .empty_o   ()
    );

    assign output_nblock = output_meta_rd_data[OUTPUT_META_WIDTH-1];
    assign output_cfg_m = output_meta_rd_data[OUTPUT_META_WIDTH-2 -: M_CNT_WIDTH];
    assign output_cfg_n = output_meta_rd_data[6 + COL_CNT_WIDTH -: COL_CNT_WIDTH];
    assign output_rs1   = output_meta_rd_data[6:5];
    assign output_kblock = output_meta_rd_data[4];
    assign output_rd    = output_meta_rd_data[3:1];
    assign output_last  = output_meta_rd_data[0];

    // 检测到新输出 block 的第一个 pre-valid beat 时，读取 FIFO 队头并
    // 锁存本次 C 读取和 A scale 读取需要的信息。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_read_m_rows  <= '0;
            rd_read_rs1     <= '0;
            rs1_scale_kblock_q <= 1'b0;
            rd_read_nblock  <= 1'b0;
            rd_read_last    <= 1'b0;
            rd_read_sel  <= '0;
            rd_zero_block_q <= 1'b0;
        end else if (output_meta_pop) begin
            rd_read_m_rows <= output_cfg_m;
            rd_read_rs1 <= output_rs1;
            rs1_scale_kblock_q <= output_kblock;
            rd_read_nblock <= output_nblock;
            rd_read_last <= output_last;
            rd_read_sel <= output_rd;
            // 每个 N 区域的 K0 使用零初值；K1 必须读取 K0 的写回结果。
            // 整块保持，确保首次遍历的所有行都旁路为零。
            rd_zero_block_q <= !c_reg_zero_n_i[output_rd[1:0]] && !output_kblock;
        end
    end

    assign rd_read_count_p1 = rd_read_count + 1'd1;
    // 输出读rd地址计数：尾部累加完成一行后，地址再加一。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_read_count <= '0;
        end
        else if (psum_pre_valid) begin
            if (rd_read_count_p1 == rd_read_m_rows)
                rd_read_count <= '0;
            else
                rd_read_count <= rd_read_count_p1;
        end
    end

    always @* begin
        rd_read_o        = rd_read_sel;
        rd_read_addr_o   = rd_read_count;
        rd_read_nblock_o = rd_read_nblock;
        rd_read_valid_o  = psum_pre_valid && !rd_zero_block_q;
    end

    /*****************************右矩阵 scale **************************************/ 
    // B scale 地址来自 weight descriptor。weight block 被取出时按执行顺序
    // 保存，等对应输出 block 到达阵列底部前再读取一次完整的 32B scale。
    assign b_scale_meta_wr_data = {tiling_rs2[1:0], tiling_weight_base_addr[5], tiling_weight_col};
    fifo #(
        .DATA_WIDTH ( B_SCALE_META_WIDTH ),
        .DEPTH      ( 8                  )
    ) u_b_scale_meta_fifo (
        .clk       ( clk                  ),
        .rst_n     ( rst_n                ),
        .wr_en_i   ( weight_pop           ),
        .wr_data_i ( b_scale_meta_wr_data ),
        .full_o    (),
        .rd_en_i   ( b_scale_meta_pop      ),
        .rd_data_o ( b_scale_meta_rd_data ),
        .empty_o   ( b_scale_meta_empty    )
    );

    assign b_scale_meta_pop = output_meta_pop;
    // output_meta_pop 比第一个 psum_valid 提前两拍。在这里发出同步 SRAM
    // 读请求，下一拍锁存 B scale，再下一拍与 psum_valid 对齐。
    always @* begin
        rs2_scale_reg_o        = b_scale_meta_rd_data[3:2];
        rs2_scale_bank_o       = b_scale_meta_rd_data[1];
        rs2_scale_kblock_o     = b_scale_meta_rd_data[0];
        rs2_scale_read_valid_o = b_scale_meta_pop;
    end

    /*****************************左矩阵 scale **************************************/ 
    // output_meta_pop 比第一个 psum_valid 提前两拍。先读取 M[0:31]
    // 的 scale；如果 M>32，则在准备第31行时预取 M[32:63]。
    assign a_scale_bank0_req = output_meta_pop;
    assign a_scale_bank1_req = psum_pre_valid &&
                               (rd_read_count == M_CNT_WIDTH'(31)) &&
                               (rd_read_m_rows > M_CNT_WIDTH'(32));

    always @* begin
        if (a_scale_bank0_req) begin
            rs1_scale_reg_o        = output_rs1;
            rs1_scale_bank_o       = 1'b0;
            rs1_scale_kblock_o     = output_kblock;
            rs1_scale_read_valid_o = 1'b1;
        end
        else begin
            rs1_scale_reg_o        = rd_read_rs1;
            rs1_scale_bank_o       = 1'b1;
            rs1_scale_kblock_o     = rs1_scale_kblock_q;
            rs1_scale_read_valid_o = a_scale_bank1_req;
        end
    end

    // 零旁路与同步 SRAM 一拍返回对齐，保持原有 psum_valid 累加时序。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rd_zero_return_q <= 1'b0;
        else
            rd_zero_return_q <= psum_pre_valid && rd_zero_block_q;
    end
    assign accum_c_data = rd_zero_return_q ? '0 : rd_data_i;

    accumulaters #(
        .TILE_COLS    ( TILE_COLS    ),
        .PE_ACC_WIDTH ( PE_ACC_WIDTH )
    ) u_accumulaters (
        .clk                      ( clk                       ),
        .rst_n                    ( rst_n                     ),
        .a_scale_data_i           ( rs1_scale_data_i          ),
        .a_scale_data_valid_i     ( rs1_scale_data_valid_i    ),
        .b_scale_data_i           ( rs2_scale_data_i          ),
        .b_scale_data_valid_i     ( rs2_scale_data_valid_i    ),
        .valid_i                  ( psum_valid                ),
        .add_pe_i                 ( psum_bottom               ),
        .add_rd_i                 ( accum_c_data              ),
        .valid_o                  ( accum_valid               ),
        .sum_o                    ( accum_sum_o               )
    );

    // 输出侧列掩码使用当前已锁存写回 block 的 N。
    always @* begin : gen_output_col_mask
        integer col_mask_idx;
        output_col_valid_mask = '0;
        for (col_mask_idx = 0; col_mask_idx < TILE_COLS; col_mask_idx = col_mask_idx + 1) begin
            if (col_mask_idx < rd_write_n_cols)
                output_col_valid_mask[col_mask_idx] = 1'b1;
        end
    end

    always @* begin : gen_output_data_mask
        integer col_mask_idx;
        pe_array_o = '0;
        for (col_mask_idx = 0; col_mask_idx < TILE_COLS; col_mask_idx = col_mask_idx + 1) begin
            if (output_col_valid_mask[col_mask_idx])
                pe_array_o[col_mask_idx*ACC_WIDTH +: ACC_WIDTH] = accum_sum_o[col_mask_idx*ACC_WIDTH +: ACC_WIDTH];
        end
    end

    // accumulation block metadata 到达阵列尾部前，将写回所需的信息压入独立
    // FIFO。队头保持到该 block 的最后一行真正完成累加写回。
    assign writeback_meta_push = output_meta_pop;
    assign writeback_meta_wr_data = {output_last, output_cfg_m, output_cfg_n, output_rd, output_nblock};

    fifo #(
        .DATA_WIDTH ( WRITEBACK_META_WIDTH ),
        .DEPTH      ( 8                    )
    ) u_writeback_meta_fifo (
        .clk       ( clk                    ),
        .rst_n     ( rst_n                  ),
        .wr_en_i   ( writeback_meta_push    ),
        .wr_data_i ( writeback_meta_wr_data ),
        .full_o    (                        ),
        .rd_en_i   ( writeback_meta_pop     ),
        .rd_data_o ( writeback_meta_rd_data ),
        .empty_o   ( writeback_meta_empty   )
    );
    // block-head 到达累加器输出前一拍时弹出 FIFO，并锁存整块保持不变
    // 的写回信息。相邻 block 连续写回时，旧信息仍服务于当前最后一行，
    // 时钟沿后再切换为下一块信息。
    assign writeback_meta_pop = output_block_head_shift[WRITEBACK_META_POP_INDEX] && !writeback_meta_empty;

    assign writeback_head_m_rows = writeback_meta_rd_data[WRITEBACK_META_WIDTH-2 -: M_CNT_WIDTH];
    assign writeback_head_last = writeback_meta_rd_data[WRITEBACK_META_WIDTH-1];
    assign writeback_head_n_cols = writeback_meta_rd_data[3 + COL_CNT_WIDTH -: COL_CNT_WIDTH];
    assign writeback_head_rd = writeback_meta_rd_data[3:1];
    assign writeback_head_nblock = writeback_meta_rd_data[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_write_m_rows  <= '0;
            rd_write_n_cols  <= '0;
            rd_write_sel     <= '0;
            rd_write_nblock  <= 1'b0;
            rd_write_last    <= 1'b0;
        end else if (writeback_meta_pop) begin
            rd_write_m_rows  <= writeback_head_m_rows;
            rd_write_n_cols  <= writeback_head_n_cols;
            rd_write_sel     <= writeback_head_rd;
            rd_write_nblock  <= writeback_head_nblock;
            rd_write_last    <= writeback_head_last;
        end
    end

    // 输出写 C 地址计数：只有融合累加器真正产生结果时才推进。
    // 当前 block 最后一行写回后，下一拍从地址 0 开始写下一个 block。
    assign rd_write_count_p1 = rd_write_count + 1'd1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_write_count <= '0;
        end
        else if (accum_valid) begin
            if (rd_write_count_p1 == rd_write_m_rows)
                rd_write_count <= '0;
            else
                rd_write_count <= rd_write_count_p1;
        end
    end

    always @* begin
        rd_write_o        = rd_write_sel;
        rd_write_addr_o   = rd_write_count[5:0];
        rd_write_nblock_o = rd_write_nblock;
        rd_write_valid_o  = accum_valid;
    end

    // C 的 zero 标志在最后一个矩阵分块完成最后一次 C 读取后解除。
    // rd_read_last 表示当前读取的矩阵分块是整条 MATMUL 的最后一个分块。
    // 无效周期 mask 必须为零。
    assign cmd_writeback_done = rd_write_valid_o && rd_write_last &&
                                 (rd_write_count_p1 == rd_write_m_rows);
    assign c_reg_zero_release_valid_o = psum_pre_valid && (rd_read_count_p1 == rd_read_m_rows) &&
                                        rd_read_last && !c_reg_zero_n_i[rd_read_sel[1:0]];
    assign c_reg_zero_release_mask_o = c_reg_zero_release_valid_o ? (4'b0001 << rd_read_sel[1:0]) : 4'b0;
                                
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            matmul_finish <= 1'b0;
        end
        else begin
            if(output_meta_pop)
                matmul_finish <= output_last;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            matmul_finish_o <= 1'b0;
        end
        else begin
            if(output_block_head_shift[TILE_ROWS-1])
                matmul_finish_o <= matmul_finish;
        end
    end

    // 状态寄存器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= Idle;
        end else begin
            state <= next_state;
        end
    end
    
    // 次态逻辑
    always @* begin
        next_state = state;

        case (state)
            Idle: begin
                if (enter_load_weight)
                    next_state = LoadWeight;
            end

            LoadWeight: begin
                if (weight_done_now) begin
                    if (!tiling_weight_empty)
                        next_state = StreamPreloadWeight;
                    else 
                        next_state = Stream;
                end
            end

            StreamPreloadWeight: begin
                if (stream_done_now && weight_done_now) begin
                    if (!tiling_weight_empty)
                        next_state = StreamPreloadWeight;
                    else
                        next_state = Stream;
                end
            end

            // Stream 状态下如果来了右矩阵应该也支持预装载右矩阵,现在该逻辑未实现
            Stream: begin
                if (stream_last) begin
                    if (enter_load_weight)
                        next_state = LoadWeight;
                    else
                        next_state = Idle;
                end
            end
            default: begin
                next_state = Idle;
            end
        endcase
    end


endmodule
