module MatrixRegFile (
    input  logic           clk,
    input  logic           rst_n,

    // Whole-tile read port 0 for the compute path.
    input  logic           tile_rd0_en_i,
    input  logic [1:0]     tile_rd0_reg_i,
    output logic [16383:0] tile_rd0_data_o,

    // Whole-tile read port 1 for the compute path.
    input  logic           tile_rd1_en_i,
    input  logic [1:0]     tile_rd1_reg_i,
    output logic [16383:0] tile_rd1_data_o,

    // Whole-acc read/write ports for the compute path.
    input  logic           acc_rd_en_i,
    input  logic [1:0]     acc_rd_reg_i,
    output logic [32767:0] acc_rd_data_o,

    input  logic           acc_wr_en_i,
    input  logic [1:0]     acc_wr_reg_i,
    input  logic [32767:0] acc_wr_data_i,

    // Legacy whole-register memory side ports.
    input  logic           tile_mem_wr_en_i,
    input  logic [1:0]     tile_mem_wr_reg_i,
    input  logic [16383:0] tile_mem_wr_data_i,
    input  logic           acc_mem_wr_en_i,
    input  logic [1:0]     acc_mem_wr_reg_i,
    input  logic [32767:0] acc_mem_wr_data_i,
    input  logic           tile_mem_rd_en_i,
    input  logic [1:0]     tile_mem_rd_reg_i,
    output logic [16383:0] tile_mem_rd_data_o,
    input  logic           acc_mem_rd_en_i,
    input  logic [1:0]     acc_mem_rd_reg_i,
    output logic [32767:0] acc_mem_rd_data_o,

    // DMA-side 256-bit beat access.
    // Read latency is fixed to one cycle because the backend uses sync SRAM.
    input  logic           mem_rd_en_i,
    input  logic           mem_rd_kind_i,
    input  logic [1:0]     mem_rd_reg_i,
    input  logic [6:0]     mem_rd_beat_i,
    output logic [255:0]   mem_rd_data_o,

    input  logic           mem_wr_en_i,
    input  logic           mem_wr_kind_i,
    input  logic [1:0]     mem_wr_reg_i,
    input  logic [6:0]     mem_wr_beat_i,
    input  logic [255:0]   mem_wr_data_i,
    input  logic [31:0]    mem_wr_strb_i,

    // Debug preload.
    input  logic           tile_dbg_wr_en_i,
    input  logic [1:0]     tile_dbg_wr_reg_i,
    input  logic [16383:0] tile_dbg_wr_data_i,

    input  logic           acc_dbg_wr_en_i,
    input  logic [1:0]     acc_dbg_wr_reg_i,
    input  logic [32767:0] acc_dbg_wr_data_i,

    // Debug readback.
    input  logic           dbg_tile_rd_en_i,
    input  logic [1:0]     dbg_tile_rd_reg_i,
    output logic [16383:0] dbg_tile_rd_data_o,

    input  logic           dbg_acc_rd_en_i,
    input  logic [1:0]     dbg_acc_rd_reg_i,
    output logic [32767:0] dbg_acc_rd_data_o
);

    localparam int TILE_REG_COUNT  = 4;
    localparam int ACC_REG_COUNT   = 4;
    localparam int TILE_WORD_BITS  = 16384;
    localparam int ACC_WORD_BITS   = 32768;
    localparam int BEAT_BITS       = 256;

    logic [TILE_WORD_BITS-1:0] tile_shadow_q [0:TILE_REG_COUNT-1];
    logic [ACC_WORD_BITS-1:0]  acc_shadow_q  [0:ACC_REG_COUNT-1];

    logic [TILE_WORD_BITS-1:0] tile_sram_q [0:TILE_REG_COUNT-1];
    logic [ACC_WORD_BITS-1:0]  acc_sram_q  [0:ACC_REG_COUNT-1];

    logic                      tile_sram_cen [0:TILE_REG_COUNT-1];
    logic                      tile_sram_wen [0:TILE_REG_COUNT-1];
    logic [0:0]                tile_sram_addr[0:TILE_REG_COUNT-1];
    logic [TILE_WORD_BITS-1:0] tile_sram_d   [0:TILE_REG_COUNT-1];

    logic                     acc_sram_cen [0:ACC_REG_COUNT-1];
    logic                     acc_sram_wen [0:ACC_REG_COUNT-1];
    logic [0:0]               acc_sram_addr[0:ACC_REG_COUNT-1];
    logic [ACC_WORD_BITS-1:0] acc_sram_d   [0:ACC_REG_COUNT-1];

    logic       init_busy_q;

    logic       mem_rd_pending_q;
    logic       mem_rd_kind_q;
    logic [1:0] mem_rd_reg_q;
    logic [6:0] mem_rd_beat_q;

    integer idx;

    function automatic [255:0] apply_strb256;
        input [255:0] old_data;
        input [255:0] new_data;
        input [31:0]  strb;
        integer byte_idx;
        begin
            apply_strb256 = old_data;
            for (byte_idx = 0; byte_idx < 32; byte_idx = byte_idx + 1) begin
                if (strb[byte_idx]) begin
                    apply_strb256[byte_idx * 8 +: 8] = new_data[byte_idx * 8 +: 8];
                end
            end
        end
    endfunction

    function automatic [255:0] tile_get_beat;
        input [TILE_WORD_BITS-1:0] word;
        input [6:0]                beat_sel;
        integer lo;
        begin
            lo = beat_sel * BEAT_BITS;
            tile_get_beat = word[lo +: BEAT_BITS];
        end
    endfunction

    function automatic [255:0] acc_get_beat;
        input [ACC_WORD_BITS-1:0] word;
        input [6:0]               beat_sel;
        integer lo;
        begin
            lo = beat_sel * BEAT_BITS;
            acc_get_beat = word[lo +: BEAT_BITS];
        end
    endfunction

    function automatic [TILE_WORD_BITS-1:0] tile_word_after_beat_write;
        input [TILE_WORD_BITS-1:0] old_word;
        input [6:0]                beat_sel;
        input [255:0]              beat_data;
        input [31:0]               beat_strb;
        reg   [TILE_WORD_BITS-1:0] tmp;
        integer lo;
        begin
            tmp = old_word;
            lo = beat_sel * BEAT_BITS;
            tmp[lo +: BEAT_BITS] = apply_strb256(old_word[lo +: BEAT_BITS], beat_data, beat_strb);
            tile_word_after_beat_write = tmp;
        end
    endfunction

    function automatic [ACC_WORD_BITS-1:0] acc_word_after_beat_write;
        input [ACC_WORD_BITS-1:0] old_word;
        input [6:0]               beat_sel;
        input [255:0]             beat_data;
        input [31:0]              beat_strb;
        reg   [ACC_WORD_BITS-1:0] tmp;
        integer lo;
        begin
            tmp = old_word;
            lo = beat_sel * BEAT_BITS;
            tmp[lo +: BEAT_BITS] = apply_strb256(old_word[lo +: BEAT_BITS], beat_data, beat_strb);
            acc_word_after_beat_write = tmp;
        end
    endfunction

    assign tile_rd0_data_o = tile_rd0_en_i ? tile_shadow_q[tile_rd0_reg_i] : '0;
    assign tile_rd1_data_o = tile_rd1_en_i ? tile_shadow_q[tile_rd1_reg_i] : '0;
    assign acc_rd_data_o = acc_rd_en_i ? acc_shadow_q[acc_rd_reg_i] : '0;

    assign tile_mem_rd_data_o = tile_mem_rd_en_i ? tile_shadow_q[tile_mem_rd_reg_i] : '0;
    assign acc_mem_rd_data_o = acc_mem_rd_en_i ? acc_shadow_q[acc_mem_rd_reg_i] : '0;

    assign dbg_tile_rd_data_o = dbg_tile_rd_en_i ? tile_shadow_q[dbg_tile_rd_reg_i] : '0;
    assign dbg_acc_rd_data_o = dbg_acc_rd_en_i ? acc_shadow_q[dbg_acc_rd_reg_i] : '0;

    always @* begin
        mem_rd_data_o = '0;
        if (mem_rd_pending_q) begin
            if (!mem_rd_kind_q) begin
                mem_rd_data_o = tile_get_beat(tile_sram_q[mem_rd_reg_q], mem_rd_beat_q);
            end else begin
                mem_rd_data_o = acc_get_beat(acc_sram_q[mem_rd_reg_q], mem_rd_beat_q);
            end
        end
    end

    always @* begin
        for (idx = 0; idx < TILE_REG_COUNT; idx = idx + 1) begin
            tile_sram_cen[idx]  = 1'b1;
            tile_sram_wen[idx]  = 1'b1;
            tile_sram_addr[idx] = 1'b0;
            tile_sram_d[idx]    = tile_shadow_q[idx];
        end

        for (idx = 0; idx < ACC_REG_COUNT; idx = idx + 1) begin
            acc_sram_cen[idx]  = 1'b1;
            acc_sram_wen[idx]  = 1'b1;
            acc_sram_addr[idx] = 1'b0;
            acc_sram_d[idx]    = acc_shadow_q[idx];
        end

        if (init_busy_q) begin
            for (idx = 0; idx < TILE_REG_COUNT; idx = idx + 1) begin
                tile_sram_cen[idx] = 1'b0;
                tile_sram_wen[idx] = 1'b0;
                tile_sram_d[idx]   = '0;
            end
            for (idx = 0; idx < ACC_REG_COUNT; idx = idx + 1) begin
                acc_sram_cen[idx] = 1'b0;
                acc_sram_wen[idx] = 1'b0;
                acc_sram_d[idx]   = '0;
            end
        end else begin
            if (tile_mem_wr_en_i) begin
                tile_sram_cen[tile_mem_wr_reg_i] = 1'b0;
                tile_sram_wen[tile_mem_wr_reg_i] = 1'b0;
                tile_sram_d[tile_mem_wr_reg_i]   = tile_mem_wr_data_i;
            end else if (tile_dbg_wr_en_i) begin
                tile_sram_cen[tile_dbg_wr_reg_i] = 1'b0;
                tile_sram_wen[tile_dbg_wr_reg_i] = 1'b0;
                tile_sram_d[tile_dbg_wr_reg_i]   = tile_dbg_wr_data_i;
            end else if (mem_wr_en_i && !mem_wr_kind_i) begin
                tile_sram_cen[mem_wr_reg_i] = 1'b0;
                tile_sram_wen[mem_wr_reg_i] = 1'b0;
                tile_sram_d[mem_wr_reg_i]   = tile_word_after_beat_write(
                    tile_shadow_q[mem_wr_reg_i], mem_wr_beat_i, mem_wr_data_i, mem_wr_strb_i);
            end else if (mem_rd_en_i && !mem_rd_kind_i) begin
                tile_sram_cen[mem_rd_reg_i] = 1'b0;
                tile_sram_wen[mem_rd_reg_i] = 1'b1;
            end

            if (acc_wr_en_i) begin
                acc_sram_cen[acc_wr_reg_i] = 1'b0;
                acc_sram_wen[acc_wr_reg_i] = 1'b0;
                acc_sram_d[acc_wr_reg_i]   = acc_wr_data_i;
            end else if (acc_mem_wr_en_i) begin
                acc_sram_cen[acc_mem_wr_reg_i] = 1'b0;
                acc_sram_wen[acc_mem_wr_reg_i] = 1'b0;
                acc_sram_d[acc_mem_wr_reg_i]   = acc_mem_wr_data_i;
            end else if (acc_dbg_wr_en_i) begin
                acc_sram_cen[acc_dbg_wr_reg_i] = 1'b0;
                acc_sram_wen[acc_dbg_wr_reg_i] = 1'b0;
                acc_sram_d[acc_dbg_wr_reg_i]   = acc_dbg_wr_data_i;
            end else if (mem_wr_en_i && mem_wr_kind_i) begin
                acc_sram_cen[mem_wr_reg_i] = 1'b0;
                acc_sram_wen[mem_wr_reg_i] = 1'b0;
                acc_sram_d[mem_wr_reg_i]   = acc_word_after_beat_write(
                    acc_shadow_q[mem_wr_reg_i], mem_wr_beat_i, mem_wr_data_i, mem_wr_strb_i);
            end else if (mem_rd_en_i && mem_rd_kind_i) begin
                acc_sram_cen[mem_rd_reg_i] = 1'b0;
                acc_sram_wen[mem_rd_reg_i] = 1'b1;
            end
        end
    end

    genvar tile_reg_idx;
    generate
        for (tile_reg_idx = 0; tile_reg_idx < TILE_REG_COUNT; tile_reg_idx = tile_reg_idx + 1) begin : g_tile_sram
            sram_sp_1x2048B u_tile_sram (
                .Q   ( tile_sram_q[tile_reg_idx]    ),
                .CLK ( clk                          ),
                .CEN ( tile_sram_cen[tile_reg_idx]  ),
                .WEN ( tile_sram_wen[tile_reg_idx]  ),
                .A   ( tile_sram_addr[tile_reg_idx] ),
                .D   ( tile_sram_d[tile_reg_idx]    )
            );
        end
    endgenerate

    genvar acc_reg_idx;
    generate
        for (acc_reg_idx = 0; acc_reg_idx < ACC_REG_COUNT; acc_reg_idx = acc_reg_idx + 1) begin : g_acc_sram
            sram_sp_1x4096B u_acc_sram (
                .Q   ( acc_sram_q[acc_reg_idx]    ),
                .CLK ( clk                        ),
                .CEN ( acc_sram_cen[acc_reg_idx]  ),
                .WEN ( acc_sram_wen[acc_reg_idx]  ),
                .A   ( acc_sram_addr[acc_reg_idx] ),
                .D   ( acc_sram_d[acc_reg_idx]    )
            );
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            init_busy_q      <= 1'b1;
            mem_rd_pending_q <= 1'b0;
            mem_rd_kind_q    <= 1'b0;
            mem_rd_reg_q     <= '0;
            mem_rd_beat_q    <= '0;

            for (idx = 0; idx < TILE_REG_COUNT; idx = idx + 1) begin
                tile_shadow_q[idx] <= '0;
            end
            for (idx = 0; idx < ACC_REG_COUNT; idx = idx + 1) begin
                acc_shadow_q[idx] <= '0;
            end
        end else begin
            init_busy_q      <= 1'b0;
            mem_rd_pending_q <= !init_busy_q && mem_rd_en_i;
            mem_rd_kind_q    <= mem_rd_kind_i;
            mem_rd_reg_q     <= mem_rd_reg_i;
            mem_rd_beat_q    <= mem_rd_beat_i;

            if (!init_busy_q) begin
                if (tile_mem_wr_en_i) begin
                    tile_shadow_q[tile_mem_wr_reg_i] <= tile_mem_wr_data_i;
                end else if (tile_dbg_wr_en_i) begin
                    tile_shadow_q[tile_dbg_wr_reg_i] <= tile_dbg_wr_data_i;
                end else if (mem_wr_en_i && !mem_wr_kind_i) begin
                    tile_shadow_q[mem_wr_reg_i] <= tile_word_after_beat_write(
                        tile_shadow_q[mem_wr_reg_i], mem_wr_beat_i, mem_wr_data_i, mem_wr_strb_i);
                end

                if (acc_wr_en_i) begin
                    acc_shadow_q[acc_wr_reg_i] <= acc_wr_data_i;
                end else if (acc_mem_wr_en_i) begin
                    acc_shadow_q[acc_mem_wr_reg_i] <= acc_mem_wr_data_i;
                end else if (acc_dbg_wr_en_i) begin
                    acc_shadow_q[acc_dbg_wr_reg_i] <= acc_dbg_wr_data_i;
                end else if (mem_wr_en_i && mem_wr_kind_i) begin
                    acc_shadow_q[mem_wr_reg_i] <= acc_word_after_beat_write(
                        acc_shadow_q[mem_wr_reg_i], mem_wr_beat_i, mem_wr_data_i, mem_wr_strb_i);
                end
            end
        end
    end

endmodule
