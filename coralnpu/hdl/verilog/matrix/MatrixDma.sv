module MatrixDma #(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 256,
    parameter int AXI_ID_W   = 1,
    parameter int REG_IDX_W  = 2,
    parameter int REG_BEAT_W = $clog2((4096 + (AXI_DATA_W / 8) - 1) / (AXI_DATA_W / 8))
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // ------------------------------------------------------------------------
    // 来自 MatrixCore 的归一化矩阵访存命令。
    // 当前结构：
    // 1. load 路径完整下沉到 MatrixDmaLoad
    // 2. store 路径暂时仍由本模块顶层维护
    // ------------------------------------------------------------------------
    input  logic                     mem_valid_i,
    output logic                     mem_ready_o,
    input  logic [31:0]              mem_pc_i,
    input  logic                     mem_dir_i,
    input  logic [2:0]               mem_reg_i,
    input  logic                     mem_layout_i,
    input  logic                     mem_whole_i,
    input  logic [1:0]               mem_elem_bytes_i,
    input  logic [31:0]              mem_base_i,
    input  logic [31:0]              mem_stride_i,
    input  logic [7:0]               mem_rows_i,
    input  logic [7:0]               mem_cols_i,

    output logic                     busy_o,
    output logic                     done_valid_o,
    output logic                     done_illegal_o,
    output logic                     done_fault_o,
    output logic [31:0]              done_pc_o,
    output logic [31:0]              done_fault_addr_o,

    // ------------------------------------------------------------------------
    // 矩阵寄存器接口。
    // 当前：
    // - load 只使用 reg_wr_*
    // - store 只使用 reg_rd_*
    // ------------------------------------------------------------------------
    output logic                     reg_rd_en_o,
    output logic                     reg_rd_kind_o,
    output logic [REG_IDX_W-1:0]     reg_rd_idx_o,
    output logic [REG_BEAT_W-1:0]    reg_rd_beat_o,
    input  logic [AXI_DATA_W-1:0]    reg_rd_data_i,

    output logic                     reg_wr_en_o,
    output logic                     reg_wr_kind_o,
    output logic [REG_IDX_W-1:0]     reg_wr_idx_o,
    output logic [REG_BEAT_W-1:0]    reg_wr_beat_o,
    output logic [AXI_DATA_W-1:0]    reg_wr_data_o,
    output logic [AXI_DATA_W/8-1:0]  reg_wr_strb_o,

    // DDR AXI Master Read Address Channel。
    output logic                     m_axi_arvalid_o,
    input  logic                     m_axi_arready_i,
    output logic [AXI_ID_W-1:0]      m_axi_arid_o,
    output logic [AXI_ADDR_W-1:0]    m_axi_araddr_o,
    output logic [7:0]               m_axi_arlen_o,
    output logic [2:0]               m_axi_arsize_o,
    output logic [1:0]               m_axi_arburst_o,

    // DDR AXI Master Read Data Channel。
    input  logic                     m_axi_rvalid_i,
    output logic                     m_axi_rready_o,
    input  logic [AXI_ID_W-1:0]      m_axi_rid_i,
    input  logic [AXI_DATA_W-1:0]    m_axi_rdata_i,
    input  logic [1:0]               m_axi_rresp_i,
    input  logic                     m_axi_rlast_i,

    // DDR AXI Master Write Address Channel。
    output logic                     m_axi_awvalid_o,
    input  logic                     m_axi_awready_i,
    output logic [AXI_ID_W-1:0]      m_axi_awid_o,
    output logic [AXI_ADDR_W-1:0]    m_axi_awaddr_o,
    output logic [7:0]               m_axi_awlen_o,
    output logic [2:0]               m_axi_awsize_o,
    output logic [1:0]               m_axi_awburst_o,

    // DDR AXI Master Write Data Channel。
    output logic                     m_axi_wvalid_o,
    input  logic                     m_axi_wready_i,
    output logic [AXI_DATA_W-1:0]    m_axi_wdata_o,
    output logic [AXI_DATA_W/8-1:0]  m_axi_wstrb_o,
    output logic                     m_axi_wlast_o,

    // DDR AXI Master Write Response Channel。
    input  logic                     m_axi_bvalid_i,
    output logic                     m_axi_bready_o,
    input  logic [AXI_ID_W-1:0]      m_axi_bid_i,
    input  logic [1:0]               m_axi_bresp_i
);

    localparam int AXI_STRB_W = AXI_DATA_W / 8;
    localparam int AXI_BEAT_LG2 = $clog2(AXI_STRB_W);
    localparam int TRAN_BYTE_NUM_W = 16;
    localparam int ELEM_BUF_W = 64;
    localparam int LOAD_CMD_QUEUE_DEPTH = 3;
    localparam logic [15:0] TILE_ROW_BYTES = 16'd64;
    localparam logic [15:0] ACC_ROW_BYTES  = 16'd128;

    typedef enum logic [2:0] {
        StoreIdle,
        StoreStart,
        StorePrep,
        StoreWriteStart,
        StoreWriteWaitBusy,
        StoreWriteWaitDone
    } store_state_e;

    // ------------------------------------------------------------------------
    // load 子系统接口
    // ------------------------------------------------------------------------
    logic                         load_mem_valid_w;
    logic                         load_mem_ready_w;
    logic                         load_busy_w;
    logic                         load_done_valid_w;
    logic                         load_done_fault_w;
    logic [31:0]                  load_done_pc_w;
    logic [31:0]                  load_done_fault_addr_w;

    logic                         load_reg_wr_en_w;
    logic                         load_reg_wr_kind_w;
    logic [REG_IDX_W-1:0]         load_reg_wr_idx_w;
    logic [REG_BEAT_W-1:0]        load_reg_wr_beat_w;
    logic [AXI_DATA_W-1:0]        load_reg_wr_data_w;
    logic [AXI_STRB_W-1:0]        load_reg_wr_strb_w;

    // ------------------------------------------------------------------------
    // store 顶层状态
    // ------------------------------------------------------------------------
    store_state_e                 store_state;
    store_state_e                 store_next_state;

    logic                         store_cmd_active;
    logic                         store_cmd_accept_w;
    logic                         store_mem_ready_w;
    logic                         store_busy_w;

    logic [31:0]                  store_pc;
    logic [2:0]                   store_reg;
    logic                         store_layout;
    logic                         store_whole;
    logic [1:0]                   store_elem_bytes;
    logic [31:0]                  store_base;
    logic [31:0]                  store_stride;
    logic [7:0]                   store_rows;
    logic [7:0]                   store_cols;

    logic [7:0]                   store_row;
    logic [7:0]                   store_col;
    logic [ELEM_BUF_W-1:0]        store_elem;

    logic                         store_reg_kind_w;
    logic [REG_IDX_W-1:0]         store_reg_idx_w;
    logic [3:0]                   store_elem_bytes_actual_w;
    logic [15:0]                  store_reg_row_bytes_w;
    logic [31:0]                  store_mem_addr_w;
    logic [15:0]                  store_reg_byte_off_w;
    logic [REG_BEAT_W-1:0]        store_reg_beat_w;
    logic [AXI_BEAT_LG2-1:0]      store_reg_lane_w;
    logic [AXI_BEAT_LG2-1:0]      store_mem_lane_w;
    logic [TRAN_BYTE_NUM_W-1:0]   store_axi_burst_byte_num_w;

    logic                         reg_rd_req_w;
    logic                         store_start_write_w;
    logic                         store_xfer_done_w;
    logic                         store_last_elem_w;
    logic                         store_cmd_complete_w;
    logic                         store_cmd_abort_w;
    logic                         store_cmd_done_w;
    logic                         store_advance_w;
    logic                         store_done_valid_w;
    logic                         store_done_fault_w;
    logic [31:0]                  store_done_pc_w;
    logic [31:0]                  store_done_fault_addr_w;

    logic [AXI_ADDR_W-1:0]        axi_write_burst_addr_w;
    logic [TRAN_BYTE_NUM_W-1:0]   axi_write_burst_byte_num_w;
    logic [AXI_DATA_W-1:0]        axi_write_data_w;

    logic                         axi_write_busy_w;
    logic [REG_BEAT_W-1:0]        axi_write_sram_addr_w;
    logic                         axi_write_sram_req_w;
    logic                         axi_write_error_w;

    logic                         m_axi_awlock_unused_w;
    logic [3:0]                   m_axi_awcache_unused_w;
    logic [2:0]                   m_axi_awprot_unused_w;
    logic [3:0]                   m_axi_awqos_unused_w;
    logic [0:0]                   m_axi_awuser_unused_w;
    logic [0:0]                   m_axi_wuser_unused_w;
    logic [0:0]                   m_axi_buser_tied_w;

    function automatic [3:0] elem_bytes_from_width;
        input [1:0] elem_width;
        begin
            case (elem_width)
                2'd0: elem_bytes_from_width = 4'd1;
                2'd1: elem_bytes_from_width = 4'd2;
                2'd2: elem_bytes_from_width = 4'd4;
                2'd3: elem_bytes_from_width = 4'd8;
                default: elem_bytes_from_width = 4'd0;
            endcase
        end
    endfunction

    function automatic [15:0] row_bytes_for_kind;
        input reg_kind;
        begin
            row_bytes_for_kind = reg_kind ? ACC_ROW_BYTES : TILE_ROW_BYTES;
        end
    endfunction

    function automatic [ELEM_BUF_W-1:0] extract_packed_elem_from_beat;
        input [AXI_DATA_W-1:0] beat_data;
        input [AXI_BEAT_LG2-1:0] byte_lane;
        input [3:0]              elem_bytes;
        integer                  byte_idx;
        begin
            extract_packed_elem_from_beat = '0;
            for (byte_idx = 0; byte_idx < 8; byte_idx = byte_idx + 1) begin
                if (byte_idx < elem_bytes) begin
                    extract_packed_elem_from_beat[byte_idx * 8 +: 8] =
                        beat_data[(byte_lane + byte_idx) * 8 +: 8];
                end
            end
        end
    endfunction

    function automatic [AXI_DATA_W-1:0] place_packed_elem_to_axi_beat;
        input [ELEM_BUF_W-1:0] packed_elem;
        input [AXI_BEAT_LG2-1:0] byte_lane;
        input [REG_BEAT_W-1:0]   beat_idx;
        input [3:0]              elem_bytes;
        integer                  byte_idx;
        integer                  abs_lane;
        begin
            place_packed_elem_to_axi_beat = '0;
            for (byte_idx = 0; byte_idx < 8; byte_idx = byte_idx + 1) begin
                if (byte_idx < elem_bytes) begin
                    abs_lane = byte_lane + byte_idx;
                    if ((beat_idx == '0) && (abs_lane < AXI_STRB_W)) begin
                        place_packed_elem_to_axi_beat[abs_lane * 8 +: 8] =
                            packed_elem[byte_idx * 8 +: 8];
                    end else if ((beat_idx == {{(REG_BEAT_W-1){1'b0}}, 1'b1}) && (abs_lane >= AXI_STRB_W)) begin
                        place_packed_elem_to_axi_beat[(abs_lane - AXI_STRB_W) * 8 +: 8] =
                            packed_elem[byte_idx * 8 +: 8];
                    end
                end
            end
        end
    endfunction

    // ------------------------------------------------------------------------
    // load / store 分流
    // 当前先做串行仲裁：
    // 1. store 忙时，不再给 load 子系统送新命令
    // 2. load 忙时，不再接收新的 store 命令
    // 这样先保证 done/status 汇总简单，后续再做真正并行
    // ------------------------------------------------------------------------
    assign load_mem_valid_w =
        mem_valid_i && !mem_dir_i && !store_busy_w && !store_done_valid_w;

    assign store_mem_ready_w =
        !store_busy_w && !load_busy_w && !load_done_valid_w;

    assign mem_ready_o =
        mem_dir_i ? store_mem_ready_w :
                    (load_mem_ready_w && !store_busy_w && !store_done_valid_w);

    assign busy_o = load_busy_w || store_busy_w;

    assign done_valid_o = load_done_valid_w || store_done_valid_w;
    assign done_illegal_o = 1'b0;
    assign done_fault_o =
        load_done_valid_w ? load_done_fault_w :
        store_done_valid_w ? store_done_fault_w : 1'b0;
    assign done_pc_o =
        load_done_valid_w ? load_done_pc_w :
        store_done_valid_w ? store_done_pc_w : 32'b0;
    assign done_fault_addr_o =
        load_done_valid_w ? load_done_fault_addr_w :
        store_done_valid_w ? store_done_fault_addr_w : 32'b0;

    assign reg_wr_en_o = load_reg_wr_en_w;
    assign reg_wr_kind_o = load_reg_wr_kind_w;
    assign reg_wr_idx_o = load_reg_wr_idx_w;
    assign reg_wr_beat_o = load_reg_wr_beat_w;
    assign reg_wr_data_o = load_reg_wr_data_w;
    assign reg_wr_strb_o = load_reg_wr_strb_w;

    // ------------------------------------------------------------------------
    // store 顶层地址生成与寄存器读口
    // ------------------------------------------------------------------------
    assign store_reg_kind_w = store_reg[2];
    assign store_reg_idx_w = store_reg[1:0];
    assign store_elem_bytes_actual_w = elem_bytes_from_width(store_elem_bytes);
    assign store_reg_row_bytes_w = row_bytes_for_kind(store_reg_kind_w);

    assign store_mem_addr_w =
        store_layout ?
            (store_base + (store_col * store_stride) + (store_row * store_elem_bytes_actual_w)) :
            (store_base + (store_row * store_stride) + (store_col * store_elem_bytes_actual_w));

    assign store_reg_byte_off_w =
        (store_row * store_reg_row_bytes_w) + (store_col * store_elem_bytes_actual_w);

    assign store_reg_beat_w = store_reg_byte_off_w >> AXI_BEAT_LG2;
    assign store_reg_lane_w = store_reg_byte_off_w[AXI_BEAT_LG2-1:0];
    assign store_mem_lane_w = store_mem_addr_w[AXI_BEAT_LG2-1:0];
    assign store_axi_burst_byte_num_w =
        {{(TRAN_BYTE_NUM_W-4){1'b0}}, store_elem_bytes_actual_w};

    assign reg_rd_en_o = reg_rd_req_w;
    assign reg_rd_kind_o = store_reg_kind_w;
    assign reg_rd_idx_o = store_reg_idx_w;
    assign reg_rd_beat_o = store_reg_beat_w;

    assign axi_write_burst_addr_w = store_mem_addr_w[AXI_ADDR_W-1:0];
    assign axi_write_burst_byte_num_w = store_axi_burst_byte_num_w;
    assign axi_write_data_w =
        place_packed_elem_to_axi_beat(
            store_elem, store_mem_lane_w, axi_write_sram_addr_w, store_elem_bytes_actual_w);

    assign store_last_elem_w =
        (store_row == (store_rows - 1'b1)) && (store_col == (store_cols - 1'b1));
    assign store_xfer_done_w =
        (store_state == StoreWriteWaitDone) && store_cmd_active && !axi_write_busy_w;
    assign store_cmd_complete_w =
        store_xfer_done_w && !axi_write_error_w && store_last_elem_w;
    assign store_cmd_abort_w =
        store_xfer_done_w && axi_write_error_w;
    assign store_cmd_done_w =
        store_cmd_complete_w || store_cmd_abort_w;
    assign store_advance_w =
        store_xfer_done_w && !axi_write_error_w && !store_last_elem_w;

    assign store_busy_w =
        store_cmd_active || store_cmd_accept_w || axi_write_busy_w ||
        store_start_write_w || (store_state != StoreIdle);

    assign store_cmd_accept_w =
        mem_valid_i && mem_dir_i && store_mem_ready_w;

    always @* begin
        reg_rd_req_w = 1'b0;
        store_start_write_w = 1'b0;
        store_next_state = store_state;

        case (store_state)
            StoreIdle: begin
                if (store_cmd_accept_w) begin
                    store_next_state = StoreStart;
                end
            end

            StoreStart: begin
                reg_rd_req_w = store_cmd_active;
                store_next_state = StorePrep;
            end

            StorePrep: begin
                store_next_state = StoreWriteStart;
            end

            StoreWriteStart: begin
                store_start_write_w = store_cmd_active;
                store_next_state = StoreWriteWaitBusy;
            end

            StoreWriteWaitBusy: begin
                if (axi_write_busy_w) begin
                    store_next_state = StoreWriteWaitDone;
                end
            end

            StoreWriteWaitDone: begin
                if (store_xfer_done_w) begin
                    if (store_cmd_done_w) begin
                        store_next_state = StoreIdle;
                    end else begin
                        store_next_state = StoreStart;
                    end
                end
            end

            default: begin
                store_next_state = StoreIdle;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            store_state <= StoreIdle;
        end else begin
            store_state <= store_next_state;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            store_cmd_active <= 1'b0;
            store_pc <= '0;
            store_reg <= '0;
            store_layout <= 1'b0;
            store_whole <= 1'b0;
            store_elem_bytes <= '0;
            store_base <= '0;
            store_stride <= '0;
            store_rows <= '0;
            store_cols <= '0;
        end else begin
            if (store_cmd_accept_w) begin
                store_cmd_active <= 1'b1;
                store_pc <= mem_pc_i;
                store_reg <= mem_reg_i;
                store_layout <= mem_layout_i;
                store_whole <= mem_whole_i;
                store_elem_bytes <= mem_elem_bytes_i;
                store_base <= mem_base_i;
                store_stride <= mem_stride_i;
                store_rows <= mem_rows_i;
                store_cols <= mem_cols_i;
            end else if (store_cmd_done_w) begin
                store_cmd_active <= 1'b0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            store_row <= '0;
            store_col <= '0;
        end else begin
            if (store_cmd_accept_w) begin
                store_row <= '0;
                store_col <= '0;
            end else if (store_advance_w) begin
                if (store_col == (store_cols - 1'b1)) begin
                    store_col <= '0;
                    store_row <= store_row + 1'b1;
                end else begin
                    store_col <= store_col + 1'b1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            store_elem <= '0;
        end else begin
            if (store_cmd_accept_w) begin
                store_elem <= '0;
            end else if (store_state == StorePrep) begin
                store_elem <= extract_packed_elem_from_beat(
                    reg_rd_data_i, store_reg_lane_w, store_elem_bytes_actual_w);
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            store_done_valid_w <= 1'b0;
            store_done_fault_w <= 1'b0;
            store_done_pc_w <= '0;
            store_done_fault_addr_w <= '0;
        end else begin
            store_done_valid_w <= 1'b0;
            store_done_fault_w <= 1'b0;

            if (store_cmd_complete_w) begin
                store_done_valid_w <= 1'b1;
                store_done_pc_w <= store_pc;
                store_done_fault_addr_w <= store_base;
            end else if (store_cmd_abort_w) begin
                store_done_valid_w <= 1'b1;
                store_done_fault_w <= 1'b1;
                store_done_pc_w <= store_pc;
                store_done_fault_addr_w <= store_mem_addr_w;
            end
        end
    end

    // ------------------------------------------------------------------------
    // load 子系统
    // ------------------------------------------------------------------------
    MatrixDmaLoad #(
        .AXI_ADDR               ( AXI_ADDR_W           ),
        .AXI_DATA               ( AXI_DATA_W           ),
        .AXI_ID                 ( AXI_ID_W             ),
        .REG_IDX                ( REG_IDX_W            ),
        .REG_BEAT               ( REG_BEAT_W           ),
        .TRAN_BYTE_NUM          ( TRAN_BYTE_NUM_W      ),
        .CMD_QUEUE_DEPTH        ( LOAD_CMD_QUEUE_DEPTH ),
        .READ_OUTSTANDING_DEPTH ( 4                    )
    ) u_matrix_dma_load (
        .clk              ( clk                    ),
        .rst_n            ( rst_n                  ),
        .mem_valid_i      ( load_mem_valid_w       ),
        .mem_ready_o      ( load_mem_ready_w       ),
        .mem_pc_i         ( mem_pc_i               ),
        .mem_reg_i        ( mem_reg_i              ),
        .mem_layout_i     ( mem_layout_i           ),
        .mem_whole_i      ( mem_whole_i            ),
        .mem_elem_bytes_i ( mem_elem_bytes_i       ),
        .mem_base_i       ( mem_base_i             ),
        .mem_stride_i     ( mem_stride_i           ),
        .mem_rows_i       ( mem_rows_i             ),
        .mem_cols_i       ( mem_cols_i             ),
        .busy_o           ( load_busy_w            ),
        .done_valid_o     ( load_done_valid_w      ),
        .done_fault_o     ( load_done_fault_w      ),
        .done_pc_o        ( load_done_pc_w         ),
        .done_fault_addr_o( load_done_fault_addr_w ),
        .reg_wr_en_o      ( load_reg_wr_en_w       ),
        .reg_wr_kind_o    ( load_reg_wr_kind_w     ),
        .reg_wr_idx_o     ( load_reg_wr_idx_w      ),
        .reg_wr_beat_o    ( load_reg_wr_beat_w     ),
        .reg_wr_data_o    ( load_reg_wr_data_w     ),
        .reg_wr_strb_o    ( load_reg_wr_strb_w     ),
        .m_axi_arvalid_o  ( m_axi_arvalid_o        ),
        .m_axi_arready_i  ( m_axi_arready_i        ),
        .m_axi_arid_o     ( m_axi_arid_o           ),
        .m_axi_araddr_o   ( m_axi_araddr_o         ),
        .m_axi_arlen_o    ( m_axi_arlen_o          ),
        .m_axi_arsize_o   ( m_axi_arsize_o         ),
        .m_axi_arburst_o  ( m_axi_arburst_o        ),
        .m_axi_rvalid_i   ( m_axi_rvalid_i         ),
        .m_axi_rready_o   ( m_axi_rready_o         ),
        .m_axi_rid_i      ( m_axi_rid_i            ),
        .m_axi_rdata_i    ( m_axi_rdata_i          ),
        .m_axi_rresp_i    ( m_axi_rresp_i          ),
        .m_axi_rlast_i    ( m_axi_rlast_i          )
    );

    // ------------------------------------------------------------------------
    // store AXI write 子路径
    // ------------------------------------------------------------------------
    AXI4_write_ctrl #(
        .AXI_ID_WIDTH         ( AXI_ID_W        ),
        .AXI_ADDR_WIDTH       ( AXI_ADDR_W      ),
        .AXI_DATA_WIDTH       ( AXI_DATA_W      ),
        .AXI_AWUSER_WIDTH     ( 1               ),
        .AXI_WUSER_WIDTH      ( 1               ),
        .AXI_BUSER_WIDTH      ( 1               ),
        .TRAN_BYTE_NUM_WIDTH  ( TRAN_BYTE_NUM_W ),
        .SRAM_ADDR_WIDTH      ( REG_BEAT_W      )
    ) u_axi4_write_ctrl (
        .clk                        ( clk                    ),
        .rst_n                      ( rst_n                  ),
        .w_target_slave_base_addr_i ( axi_write_burst_addr_w ),
        .w_total_byte_num_i         ( axi_write_burst_byte_num_w ),
        .w_start_i                  ( store_start_write_w    ),
        .w_data_i                   ( axi_write_data_w       ),
        .w_busy_o                   ( axi_write_busy_w       ),
        .w_sram_addr_o              ( axi_write_sram_addr_w  ),
        .w_sram_data_request_o      ( axi_write_sram_req_w   ),
        .w_error_o                  ( axi_write_error_w      ),
        .M_AXI_AWID                 ( m_axi_awid_o           ),
        .M_AXI_AWADDR               ( m_axi_awaddr_o         ),
        .M_AXI_AWLEN                ( m_axi_awlen_o          ),
        .M_AXI_AWSIZE               ( m_axi_awsize_o         ),
        .M_AXI_AWBURST              ( m_axi_awburst_o        ),
        .M_AXI_AWLOCK               ( m_axi_awlock_unused_w  ),
        .M_AXI_AWCACHE              ( m_axi_awcache_unused_w ),
        .M_AXI_AWPROT               ( m_axi_awprot_unused_w  ),
        .M_AXI_AWQOS                ( m_axi_awqos_unused_w   ),
        .M_AXI_AWUSER               ( m_axi_awuser_unused_w  ),
        .M_AXI_AWVALID              ( m_axi_awvalid_o        ),
        .M_AXI_AWREADY              ( m_axi_awready_i        ),
        .M_AXI_WDATA                ( m_axi_wdata_o          ),
        .M_AXI_WSTRB                ( m_axi_wstrb_o          ),
        .M_AXI_WLAST                ( m_axi_wlast_o          ),
        .M_AXI_WUSER                ( m_axi_wuser_unused_w   ),
        .M_AXI_WVALID               ( m_axi_wvalid_o         ),
        .M_AXI_WREADY               ( m_axi_wready_i         ),
        .M_AXI_BID                  ( m_axi_bid_i            ),
        .M_AXI_BRESP                ( m_axi_bresp_i          ),
        .M_AXI_BUSER                ( m_axi_buser_tied_w     ),
        .M_AXI_BVALID               ( m_axi_bvalid_i         ),
        .M_AXI_BREADY               ( m_axi_bready_o         )
    );

    assign m_axi_buser_tied_w = '0;

endmodule
