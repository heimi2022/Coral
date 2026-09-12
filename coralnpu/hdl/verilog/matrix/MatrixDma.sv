module MatrixDma #(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 512,
    parameter int AXI_ID_W   = 1,
    parameter int REG_IDX_W  = 2
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // Count encoding: 000/001/011/111 = 1/2/4/8 registers.
    // Payload must remain stable while valid is asserted and ready is low.
    input  logic                     zero_valid_i,
    output logic                     zero_ready_o,
    input  logic [31:0]              zero_pc_i,
    input  logic [2:0]               zero_md_i,
    input  logic [2:0]               zero_reg_count_i,

    // Matrix commands: mem_store_i selects STORE, otherwise LOAD.
    input  logic                     mem_valid_i,
    output logic                     mem_ready_o,
    input  logic                     mem_store_i,
    input  logic [31:0]              mem_pc_i,
    input  logic [2:0]               mem_reg_i,
    input  logic                     mem_ab_scale_sel_i, // 0: AB matrix, 1: AB scale
    input  logic [1:0]               mem_elem_bytes_i,
    input  logic [31:0]              mem_base_i,
    input  logic [31:0]              mem_stride_i,
    input  logic [7:0]               mem_rows_i,
    input  logic [7:0]               mem_cols_i,

    // Generic matrix-register read port used by store operations.
    output logic                     matrix_rd_en_o,
    output logic [REG_IDX_W-1:0]     matrix_rd_reg_o,
    output logic [5:0]               matrix_rd_addr_o,
    output logic                     matrix_rd_nblock_o,
    output logic                     matrix_rd_half_o,
    output logic [1:0]               matrix_rd_source_sel_o,
    input  logic                     matrix_rd_valid_i,
    input  logic [AXI_DATA_W-1:0]    matrix_rd_data_i,

    output logic                     busy_o,
    output logic                     done_valid_o,
    output logic                     done_illegal_o,
    output logic                     done_fault_o,
    output logic [31:0]              done_pc_o,
    output logic [31:0]              done_fault_addr_o,

    // AB 数据/scale 寄存器整行写口。
    output logic                     ab_wr_en_o,
    output logic [REG_IDX_W-1:0]     ab_wr_reg_o,
    output logic [5:0]               ab_wr_row_o,
    output logic [AXI_DATA_W-1:0]    ab_wr_data_o,
    output logic                     ab_wr_dst_sel_o,
    output logic                     c_wr_en_o,
    output logic                     c_wr_half_o,
    output logic                     c_wr_nblock_o,

    // DDR AXI master read address channel。
    output logic                     m_axi_arvalid_o,
    input  logic                     m_axi_arready_i,
    output logic [AXI_ID_W-1:0]      m_axi_arid_o,
    output logic [AXI_ADDR_W-1:0]    m_axi_araddr_o,
    output logic [7:0]               m_axi_arlen_o,
    output logic [2:0]               m_axi_arsize_o,
    output logic [1:0]               m_axi_arburst_o,

    // DDR AXI master read data channel。
    input  logic                     m_axi_rvalid_i,
    output logic                     m_axi_rready_o,
    input  logic [AXI_ID_W-1:0]      m_axi_rid_i,
    input  logic [AXI_DATA_W-1:0]    m_axi_rdata_i,
    input  logic [1:0]               m_axi_rresp_i,
    input  logic                     m_axi_rlast_i,

    // DDR AXI master write channels.
    output logic                     m_axi_awvalid_o,
    input  logic                     m_axi_awready_i,
    output logic [AXI_ID_W-1:0]      m_axi_awid_o,
    output logic [AXI_ADDR_W-1:0]    m_axi_awaddr_o,
    output logic [7:0]               m_axi_awlen_o,
    output logic [2:0]               m_axi_awsize_o,
    output logic [1:0]               m_axi_awburst_o,
    output logic                     m_axi_wvalid_o,
    input  logic                     m_axi_wready_i,
    output logic [AXI_DATA_W-1:0]    m_axi_wdata_o,
    output logic [AXI_DATA_W/8-1:0]  m_axi_wstrb_o,
    output logic                     m_axi_wlast_o,
    input  logic                     m_axi_bvalid_i,
    output logic                     m_axi_bready_o,
    input  logic [AXI_ID_W-1:0]      m_axi_bid_i,
    input  logic [1:0]               m_axi_bresp_i
);

    localparam int LOAD_CMD_QUEUE_DEPTH = 3;

    // AXI 读返回错误由 MatrixDmaLoad 汇报为 fault；对 MatrixCore 来说，
    // 这类 DMA 完成属于 illegal/error 完成，必须透传到 done_illegal_o。
    assign done_illegal_o = done_fault_o;

    logic load_mem_ready_w;
    logic load_busy_w;
    logic load_done_valid_w;
    logic load_done_fault_w;
    logic [31:0] load_done_pc_w;
    logic [31:0] load_done_fault_addr_w;
    logic store_mem_ready_w;
    logic store_busy_w;
    logic store_done_valid_w;
    logic store_done_fault_w;
    logic [31:0] store_done_pc_w;
    logic [AXI_ADDR_W-1:0] store_done_fault_addr_w;
    logic store_awvalid_w;
    logic store_wvalid_w;
    logic [AXI_ID_W-1:0] store_awid_w;
    logic [AXI_ADDR_W-1:0] store_awaddr_w;
    logic [7:0] store_awlen_w;
    logic [2:0] store_awsize_w;
    logic [1:0] store_awburst_w;
    logic [AXI_DATA_W-1:0] store_wdata_w;
    logic [AXI_DATA_W/8-1:0] store_wstrb_w;
    logic store_wlast_w;
    logic store_bready_w;

    logic store_done_pending_q;
    logic store_fault_q;
    logic [31:0] store_pc_q;
    logic [31:0] store_fault_addr_q;
    wire store_accept_enable = !store_done_pending_q && !store_done_valid_w;

    assign mem_ready_o = mem_store_i ? (store_mem_ready_w && store_accept_enable) : load_mem_ready_w;
    assign busy_o = load_busy_w || store_busy_w || store_done_pending_q;
    // LOAD/ZERO completion is a pulse and cannot be stalled. Retain STORE
    // completion until the shared port is free; block new stores meanwhile.
    assign done_valid_o = load_done_valid_w || store_done_pending_q;
    assign done_fault_o = done_valid_o && (load_done_valid_w ? load_done_fault_w : store_fault_q);
    assign done_pc_o = load_done_valid_w ? load_done_pc_w : store_pc_q;
    assign done_fault_addr_o = load_done_valid_w ? load_done_fault_addr_w : store_fault_addr_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            store_done_pending_q <= 1'b0;
            store_fault_q <= 1'b0;
            store_pc_q <= '0;
            store_fault_addr_q <= '0;
        end else begin
            if (store_done_pending_q && !load_done_valid_w)
                store_done_pending_q <= 1'b0;
            if (store_done_valid_w) begin
                store_done_pending_q <= 1'b1;
                store_fault_q <= store_done_fault_w;
                store_pc_q <= store_done_pc_w;
                store_fault_addr_q <= store_done_fault_addr_w;
            end
        end
    end
    assign m_axi_awvalid_o = store_awvalid_w;
    assign m_axi_awid_o    = store_awid_w;
    assign m_axi_awaddr_o  = store_awaddr_w;
    assign m_axi_awlen_o   = store_awlen_w;
    assign m_axi_awsize_o  = store_awsize_w;
    assign m_axi_awburst_o = store_awburst_w;
    assign m_axi_wvalid_o  = store_wvalid_w;
    assign m_axi_wdata_o   = store_wdata_w;
    assign m_axi_wstrb_o   = store_wstrb_w;
    assign m_axi_wlast_o   = store_wlast_w;
    assign m_axi_bready_o  = store_bready_w;

    MatrixDmaLoad #(
        .AXI_ADDR               ( AXI_ADDR_W           ),
        .AXI_DATA               ( AXI_DATA_W           ),
        .AXI_ID                 ( AXI_ID_W             ),
        .REG_IDX                ( REG_IDX_W            ),
            .ROW_BYTE_W             ( 9                    ),
        .CMD_QUEUE_DEPTH        ( LOAD_CMD_QUEUE_DEPTH ),
        .READ_OUTSTANDING_DEPTH ( 4                    )
    ) u_matrix_dma_load (
        .clk              ( clk                    ),
        .rst_n            ( rst_n                  ),
        .zero_valid_i     ( zero_valid_i           ),
        .zero_ready_o     ( zero_ready_o           ),
        .zero_pc_i        ( zero_pc_i              ),
        .zero_md_i        ( zero_md_i              ),
        .zero_reg_count_i ( zero_reg_count_i       ),
        .mem_valid_i      ( mem_valid_i && !mem_store_i ),
        .mem_ready_o      ( load_mem_ready_w       ),
        .mem_pc_i         ( mem_pc_i               ),
        .mem_reg_i        ( mem_reg_i              ),
        .mem_ab_scale_sel_i ( mem_ab_scale_sel_i   ),
        .mem_elem_bytes_i ( mem_elem_bytes_i       ),
        .mem_base_i       ( mem_base_i             ),
        .mem_stride_i     ( mem_stride_i           ),
        .mem_rows_i       ( mem_rows_i             ),
        .mem_cols_i       ( mem_cols_i             ),
        .busy_o           ( load_busy_w             ),
        .done_valid_o     ( load_done_valid_w       ),
        .done_fault_o     ( load_done_fault_w       ),
        .done_pc_o        ( load_done_pc_w          ),
        .done_fault_addr_o( load_done_fault_addr_w  ),
        .ab_wr_en_o       ( ab_wr_en_o             ),
        .ab_wr_reg_o      ( ab_wr_reg_o            ),
        .ab_wr_row_o      ( ab_wr_row_o            ),
        .ab_wr_data_o     ( ab_wr_data_o           ),
        .ab_wr_dst_sel_o  ( ab_wr_dst_sel_o        ),
        .c_wr_en_o        ( c_wr_en_o              ),
        .c_wr_half_o      ( c_wr_half_o            ),
        .c_wr_nblock_o    ( c_wr_nblock_o          ),
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

    MatrixDmaStore #(
        .AXI_ADDR_W       ( AXI_ADDR_W ),
        .AXI_DATA_W       ( AXI_DATA_W ),
        .AXI_ID_W         ( AXI_ID_W   ),
        .REG_IDX_W        ( REG_IDX_W )
    ) u_matrix_dma_store (
        .clk                    ( clk                    ),
        .rst_n                  ( rst_n                  ),
        .cmd_valid_i            ( mem_valid_i && mem_store_i && store_accept_enable ),
        .cmd_ready_o            ( store_mem_ready_w       ),
        .cmd_pc_i               ( mem_pc_i                ),
        .cmd_reg_i              ( mem_reg_i[REG_IDX_W-1:0] ),
        // 0: AB, 1: AB scale, 2: C. mem_ab_scale_sel_i only selects AB/scale.
        .cmd_source_sel_i       ( mem_reg_i[2] ? 2'd2 : (mem_ab_scale_sel_i ? 2'd1 : 2'd0) ),
        .cmd_elem_bytes_i       ( mem_elem_bytes_i         ),
        .cmd_base_i             ( mem_base_i               ),
        .cmd_stride_i           ( mem_stride_i             ),
        .cmd_rows_i             ( mem_rows_i               ),
        .cmd_cols_i             ( mem_cols_i               ),
        .busy_o                 ( store_busy_w             ),
        .done_valid_o           ( store_done_valid_w       ),
        .done_fault_o           ( store_done_fault_w       ),
        .done_pc_o              ( store_done_pc_w          ),
        .done_fault_addr_o      ( store_done_fault_addr_w  ),
        .matrix_rd_en_o         ( matrix_rd_en_o            ),
        .matrix_rd_reg_o        ( matrix_rd_reg_o           ),
        .matrix_rd_addr_o       ( matrix_rd_addr_o          ),
        .matrix_rd_nblock_o     ( matrix_rd_nblock_o        ),
        .matrix_rd_half_o       ( matrix_rd_half_o          ),
        .matrix_rd_source_sel_o ( matrix_rd_source_sel_o    ),
        .matrix_rd_valid_i      ( matrix_rd_valid_i         ),
        .matrix_rd_data_i       ( matrix_rd_data_i          ),
        .m_axi_awvalid_o        ( store_awvalid_w           ),
        .m_axi_awready_i        ( m_axi_awready_i          ),
        .m_axi_awid_o           ( store_awid_w              ),
        .m_axi_awaddr_o         ( store_awaddr_w            ),
        .m_axi_awlen_o          ( store_awlen_w             ),
        .m_axi_awsize_o         ( store_awsize_w            ),
        .m_axi_awburst_o        ( store_awburst_w           ),
        .m_axi_wvalid_o         ( store_wvalid_w            ),
        .m_axi_wready_i         ( m_axi_wready_i            ),
        .m_axi_wdata_o          ( store_wdata_w             ),
        .m_axi_wstrb_o          ( store_wstrb_w              ),
        .m_axi_wlast_o          ( store_wlast_w             ),
        .m_axi_bvalid_i         ( m_axi_bvalid_i            ),
        .m_axi_bready_o         ( store_bready_w            ),
        .m_axi_bid_i            ( m_axi_bid_i               ),
        .m_axi_bresp_i          ( m_axi_bresp_i             )
    );

endmodule
