/*
 * Generic matrix-register to DDR store engine.
 *
 * The matrix read port is synchronous: matrix_rd_en_o is a one-cycle request
 * and matrix_rd_valid_i returns the corresponding 64B beat.  The returned
 * beat is held until the AXI W channel accepts it.
 *
 * A command is transferred in row-major order.  Each row is one AXI burst;
 * the source register address is the row index, while source_nblock/source_half
 * select the 64B beat within that row.  This layout matches the current C
 * register file and keeps the store engine independent of the register-file
 * implementation.
 * This first version requires beat-aligned row addresses and at most four
 * beats per row. Rows crossing 4KB are reported as faults, not split.
 * Each matrix read request must be accepted; arbitration is external.
 */
module MatrixDmaStore #(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 512,
    parameter int AXI_ID_W   = 1,
    parameter int REG_IDX_W  = 2,
    parameter int ROW_IDX_W  = 6
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // Generic matrix-store command.
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

    // Generic matrix-register read port.  The current register file returns
    // one 64B bank selected by row parity, N block, and half.
    output logic                         matrix_rd_en_o,
    output logic [REG_IDX_W-1:0]         matrix_rd_reg_o,
    output logic [ROW_IDX_W-1:0]         matrix_rd_addr_o,
    output logic                         matrix_rd_nblock_o,
    output logic                         matrix_rd_half_o,
    output logic [1:0]                   matrix_rd_source_sel_o,
    input  logic                         matrix_rd_valid_i,
    input  logic [AXI_DATA_W-1:0]        matrix_rd_data_i,

    // AXI4 write master.
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

    localparam int BYTE_COUNT = AXI_DATA_W / 8;
    localparam int BYTE_LG2   = $clog2(BYTE_COUNT);
    localparam int ROW_BYTES_W = 10;

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_ROW_CHECK,
        ST_READ_REQ,
        ST_READ_WAIT,
        ST_WRITE,
        ST_RESP
    } state_t;

    state_t state_q;

    logic [31:0]                  cmd_pc_q;
    logic [REG_IDX_W-1:0]         cmd_reg_q;
    logic [1:0]                   cmd_source_sel_q;
    logic [AXI_ADDR_W-1:0]        cmd_base_q;
    logic [31:0]                  cmd_stride_q;
    logic [7:0]                   cmd_rows_q;
    logic [ROW_BYTES_W-1:0]       row_bytes_q;
    logic [7:0]                   row_beats_q;
    logic [7:0]                   row_q;
    logic [7:0]                   beat_q;
    logic [AXI_ADDR_W-1:0]        row_addr_q;
    logic [AXI_DATA_W-1:0]        data_q;
    logic                         data_valid_q;
    logic                         aw_done_q;
    logic                         fault_q;
    logic [AXI_ADDR_W-1:0]        fault_addr_q;
    logic                         done_valid_q;

    logic [ROW_BYTES_W-1:0]       row_bytes_calc;
    logic [7:0]                   row_beats_calc;
    logic [AXI_DATA_W/8-1:0]      last_strb_mask;
    integer                       strb_idx;

    wire cmd_fire = cmd_valid_i && cmd_ready_o;
    wire aw_fire  = m_axi_awvalid_o && m_axi_awready_i;
    wire w_fire   = m_axi_wvalid_o && m_axi_wready_i;
    wire b_fire   = m_axi_bvalid_i && m_axi_bready_o;

    assign cmd_ready_o = (state_q == ST_IDLE);
    assign busy_o = (state_q != ST_IDLE) || done_valid_q;
    assign done_valid_o = done_valid_q;
    assign done_fault_o = done_valid_q && fault_q;
    assign done_pc_o = cmd_pc_q;
    assign done_fault_addr_o = fault_addr_q;

    always @* begin
        row_bytes_calc = {2'b0, cmd_cols_i} << cmd_elem_bytes_i;
        row_beats_calc = (row_bytes_calc + BYTE_COUNT - 1) >> BYTE_LG2;
        if (row_beats_calc == 0)
            row_beats_calc = 8'd1;
    end

    always @* begin
        last_strb_mask = {BYTE_COUNT{1'b1}};
        if ((row_bytes_q[BYTE_LG2-1:0] != 0) &&
            (beat_q == row_beats_q - 1'b1)) begin
            last_strb_mask = '0;
            for (strb_idx = 0; strb_idx < BYTE_COUNT; strb_idx = strb_idx + 1)
                if (strb_idx < row_bytes_q[BYTE_LG2-1:0])
                    last_strb_mask[strb_idx] = 1'b1;
        end
    end

    always @* begin
        matrix_rd_en_o         = (state_q == ST_READ_REQ);
        matrix_rd_reg_o        = cmd_reg_q;
        matrix_rd_addr_o       = row_q[ROW_IDX_W-1:0];
        matrix_rd_nblock_o     = beat_q[1];
        matrix_rd_half_o       = beat_q[0];
        matrix_rd_source_sel_o = cmd_source_sel_q;

        // Keep AWVALID asserted even if W finishes before AW is accepted.
        m_axi_awvalid_o = (state_q != ST_IDLE) && (state_q != ST_ROW_CHECK) && !aw_done_q;
        m_axi_awid_o    = '0;
        m_axi_awaddr_o  = row_addr_q;
        m_axi_awlen_o   = row_beats_q - 1'b1;
        m_axi_awsize_o  = BYTE_LG2[2:0];
        m_axi_awburst_o = 2'b01;

        m_axi_wvalid_o = (state_q == ST_WRITE) && data_valid_q;
        m_axi_wdata_o  = data_q;
        m_axi_wstrb_o  = last_strb_mask;
        m_axi_wlast_o  = (beat_q == row_beats_q - 1'b1);

        m_axi_bready_o = (state_q == ST_RESP);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q       <= ST_IDLE;
            cmd_pc_q      <= '0;
            cmd_reg_q     <= '0;
            cmd_source_sel_q <= '0;
            cmd_base_q    <= '0;
            cmd_stride_q  <= '0;
            cmd_rows_q    <= '0;
            row_bytes_q   <= '0;
            row_beats_q   <= '0;
            row_q         <= '0;
            beat_q        <= '0;
            row_addr_q    <= '0;
            data_q        <= '0;
            data_valid_q  <= 1'b0;
            aw_done_q     <= 1'b0;
            fault_q       <= 1'b0;
            fault_addr_q  <= '0;
            done_valid_q  <= 1'b0;
        end else begin
            done_valid_q <= 1'b0;
            if (aw_fire)
                aw_done_q <= 1'b1;

            case (state_q)
                ST_IDLE: begin
                    if (cmd_fire) begin
                        cmd_pc_q         <= cmd_pc_i;
                        cmd_reg_q        <= cmd_reg_i;
                        cmd_source_sel_q <= cmd_source_sel_i;
                        cmd_base_q       <= cmd_base_i;
                        cmd_stride_q     <= cmd_stride_i;
                        cmd_rows_q       <= cmd_rows_i;
                        row_bytes_q      <= row_bytes_calc;
                        row_beats_q      <= row_beats_calc;
                        row_q            <= '0;
                        beat_q           <= '0;
                        row_addr_q       <= cmd_base_i;
                        data_valid_q     <= 1'b0;
                        aw_done_q        <= 1'b0;
                        fault_q          <= 1'b0;
                        fault_addr_q     <= '0;
                        // Current source addressing covers four banks per row.
                        // Reject unsupported layouts before issuing AXI traffic.
                        if ((cmd_rows_i == 0) || (cmd_cols_i == 0) ||
                            (cmd_rows_i > (1 << ROW_IDX_W)) ||
                            (cmd_elem_bytes_i > 2) || (row_beats_calc > 4) ||
                            (cmd_base_i[BYTE_LG2-1:0] != 0) ||
                            ((cmd_rows_i > 1) && (cmd_stride_i[BYTE_LG2-1:0] != 0))) begin
                            fault_q      <= 1'b1;
                            fault_addr_q <= cmd_base_i;
                            done_valid_q <= 1'b1;
                            state_q      <= ST_IDLE;
                        end else begin
                            state_q <= ST_ROW_CHECK;
                        end
                    end
                end

                ST_ROW_CHECK: begin
                    if (({1'b0, row_addr_q[11:0]} + (row_beats_q * BYTE_COUNT)) > 4096) begin
                        fault_q <= 1'b1;
                        fault_addr_q <= row_addr_q;
                        done_valid_q <= 1'b1;
                        state_q <= ST_IDLE;
                    end else begin
                        state_q <= ST_READ_REQ;
                    end
                end

                ST_READ_REQ: begin
                    state_q <= ST_READ_WAIT;
                end

                ST_READ_WAIT: begin
                    if (matrix_rd_valid_i) begin
                        data_q       <= matrix_rd_data_i;
                        data_valid_q <= 1'b1;
                        state_q      <= ST_WRITE;
                    end
                end

                ST_WRITE: begin
                    if (w_fire) begin
                        data_valid_q <= 1'b0;
                        if (!m_axi_wlast_o) begin
                            beat_q  <= beat_q + 1'b1;
                            state_q <= ST_READ_REQ;
                        end else begin
                            state_q <= ST_RESP;
                        end
                    end
                end

                ST_RESP: begin
                    if (b_fire) begin
                        if (m_axi_bresp_i[1]) begin
                            fault_q      <= 1'b1;
                            fault_addr_q <= row_addr_q;
                            state_q      <= ST_IDLE;
                            done_valid_q <= 1'b1;
                        end else if (row_q == cmd_rows_q - 1'b1) begin
                            state_q      <= ST_IDLE;
                            done_valid_q <= 1'b1;
                        end else begin
                            row_q       <= row_q + 1'b1;
                            beat_q      <= '0;
                            row_addr_q  <= row_addr_q + cmd_stride_q;
                            aw_done_q   <= 1'b0;
                            state_q      <= ST_ROW_CHECK;
                        end
                    end
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end

endmodule
