module MatrixRegFile (
    input  logic         clk,
    input  logic         rst_n,

    // tile read port 0 : whole tile
    input  logic         tile_rd0_en_i,
    input  logic [1:0]   tile_rd0_reg_i,
    output logic [1023:0] tile_rd0_data_o,

    // tile read port 1 : whole tile
    input  logic         tile_rd1_en_i,
    input  logic [1:0]   tile_rd1_reg_i,
    output logic [1023:0] tile_rd1_data_o,

    // acc read port : whole acc register
    input  logic         acc_rd_en_i,
    input  logic [1:0]   acc_rd_reg_i,
    output logic [511:0] acc_rd_data_o,

    // acc write port : whole acc register
    input  logic         acc_wr_en_i,
    input  logic [1:0]   acc_wr_reg_i,
    input  logic [511:0] acc_wr_data_i,

    // debug preload
    input  logic         tile_dbg_wr_en_i,
    input  logic [1:0]   tile_dbg_wr_reg_i,
    input  logic [1023:0] tile_dbg_wr_data_i,

    input  logic         acc_dbg_wr_en_i,
    input  logic [1:0]   acc_dbg_wr_reg_i,
    input  logic [511:0] acc_dbg_wr_data_i,

    // debug readback
    input  logic         dbg_tile_rd_en_i,
    input  logic [1:0]   dbg_tile_rd_reg_i,
    output logic [1023:0] dbg_tile_rd_data_o,

    input  logic         dbg_acc_rd_en_i,
    input  logic [1:0]   dbg_acc_rd_reg_i,
    output logic [511:0] dbg_acc_rd_data_o
);

    logic [1023:0] tile_q [0:3];
    logic [511:0]  acc_q  [0:3];

    integer idx;

    assign tile_rd0_data_o = tile_rd0_en_i ? tile_q[tile_rd0_reg_i] : '0;
    assign tile_rd1_data_o = tile_rd1_en_i ? tile_q[tile_rd1_reg_i] : '0;
    assign acc_rd_data_o = acc_rd_en_i ? acc_q[acc_rd_reg_i] : '0;

    assign dbg_tile_rd_data_o = dbg_tile_rd_en_i ? tile_q[dbg_tile_rd_reg_i] : '0;
    assign dbg_acc_rd_data_o = dbg_acc_rd_en_i ? acc_q[dbg_acc_rd_reg_i] : '0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (idx = 0; idx < 4; idx = idx + 1) begin
                tile_q[idx] <= '0;
            end
            for (idx = 0; idx < 4; idx = idx + 1) begin
                acc_q[idx] <= '0;
            end
        end else begin
            if (tile_dbg_wr_en_i) begin
                tile_q[tile_dbg_wr_reg_i] <= tile_dbg_wr_data_i;
            end

            if (acc_wr_en_i) begin
                acc_q[acc_wr_reg_i] <= acc_wr_data_i;
            end

            if (acc_dbg_wr_en_i) begin
                acc_q[acc_dbg_wr_reg_i] <= acc_dbg_wr_data_i;
            end
        end
    end
endmodule
