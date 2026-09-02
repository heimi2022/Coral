module MatrixDma #(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 512,
    parameter int AXI_ID_W   = 1,
    parameter int REG_IDX_W  = 2
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // 来自 MatrixCore 的矩阵 load 命令。
    input  logic                     mem_valid_i,
    output logic                     mem_ready_o,
    input  logic [31:0]              mem_pc_i,
    input  logic [2:0]               mem_reg_i,
    input  logic                     mem_dst_sel_i,
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

    // AB 数据/scale 寄存器整行写口。
    output logic                     ab_wr_en_o,
    output logic [REG_IDX_W-1:0]     ab_wr_reg_o,
    output logic [5:0]               ab_wr_row_o,
    output logic [AXI_DATA_W-1:0]    ab_wr_data_o,
    output logic                     ab_wr_dst_sel_o,

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
    input  logic                     m_axi_rlast_i
);

    localparam int LOAD_CMD_QUEUE_DEPTH = 3;

    // AXI 读返回错误由 MatrixDmaLoad 汇报为 fault；对 MatrixCore 来说，
    // 这类 DMA 完成属于 illegal/error 完成，必须透传到 done_illegal_o。
    assign done_illegal_o = done_fault_o;

    MatrixDmaLoad #(
        .AXI_ADDR               ( AXI_ADDR_W           ),
        .AXI_DATA               ( AXI_DATA_W           ),
        .AXI_ID                 ( AXI_ID_W             ),
        .REG_IDX                ( REG_IDX_W            ),
        .ROW_BYTE_W             ( 7                    ),
        .CMD_QUEUE_DEPTH        ( LOAD_CMD_QUEUE_DEPTH ),
        .READ_OUTSTANDING_DEPTH ( 4                    )
    ) u_matrix_dma_load (
        .clk              ( clk                    ),
        .rst_n            ( rst_n                  ),
        .mem_valid_i      ( mem_valid_i            ),
        .mem_ready_o      ( mem_ready_o            ),
        .mem_pc_i         ( mem_pc_i               ),
        .mem_reg_i        ( mem_reg_i              ),
        .mem_dst_sel_i    ( mem_dst_sel_i          ),
        .mem_elem_bytes_i ( mem_elem_bytes_i       ),
        .mem_base_i       ( mem_base_i             ),
        .mem_stride_i     ( mem_stride_i           ),
        .mem_rows_i       ( mem_rows_i             ),
        .mem_cols_i       ( mem_cols_i             ),
        .busy_o           ( busy_o                 ),
        .done_valid_o     ( done_valid_o           ),
        .done_fault_o     ( done_fault_o           ),
        .done_pc_o        ( done_pc_o              ),
        .done_fault_addr_o( done_fault_addr_o      ),
        .ab_wr_en_o       ( ab_wr_en_o             ),
        .ab_wr_reg_o      ( ab_wr_reg_o            ),
        .ab_wr_row_o      ( ab_wr_row_o            ),
        .ab_wr_data_o     ( ab_wr_data_o           ),
        .ab_wr_dst_sel_o  ( ab_wr_dst_sel_o        ),
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

endmodule
