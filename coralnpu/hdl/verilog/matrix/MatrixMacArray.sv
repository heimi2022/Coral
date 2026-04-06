module MatrixMacArray (
    input  logic [1023:0] a_tile_i,
    input  logic [1023:0] b_tile_i,
    input  logic [511:0]  c_acc_i,
    input  logic [31:0]   cfg_m_i,
    input  logic [31:0]   cfg_k_i,
    input  logic [31:0]   cfg_n_i,
    input  logic          sat_en_i,
    output logic [511:0]  c_acc_o,
    output logic          sat_o
);

    localparam integer ROW_COUNT     = 4;
    localparam integer COL_COUNT     = 4;
    localparam integer TILE_ROW_BITS = 256;
    localparam integer ACC_ROW_BITS  = 128;
    localparam integer ACC_ELEM_BITS = 32;

    logic [255:0] a_row_w [0:ROW_COUNT-1];
    logic [255:0] b_row_w [0:COL_COUNT-1];
    logic [31:0]  pe_result_w [0:ROW_COUNT-1][0:COL_COUNT-1];
    logic         pe_sat_w [0:ROW_COUNT-1][0:COL_COUNT-1];

    integer row;
    integer col;
    genvar pe_row;
    genvar pe_col;

    generate
        for (pe_row = 0; pe_row < ROW_COUNT; pe_row = pe_row + 1) begin : gen_a_rows
            assign a_row_w[pe_row] = a_tile_i[pe_row * TILE_ROW_BITS +: TILE_ROW_BITS];
        end

        for (pe_col = 0; pe_col < COL_COUNT; pe_col = pe_col + 1) begin : gen_b_rows
            assign b_row_w[pe_col] = b_tile_i[pe_col * TILE_ROW_BITS +: TILE_ROW_BITS];
        end

        for (pe_row = 0; pe_row < ROW_COUNT; pe_row = pe_row + 1) begin : gen_pe_rows
            for (pe_col = 0; pe_col < COL_COUNT; pe_col = pe_col + 1) begin : gen_pe_cols
                MatrixPE32Int8 pe_u (
                    .a_vec_i (a_row_w[pe_row]),
                    .b_vec_i (b_row_w[pe_col]),
                    .acc_i   (c_acc_i[pe_row * ACC_ROW_BITS + pe_col * ACC_ELEM_BITS +: ACC_ELEM_BITS]),
                    .cfg_k_i (cfg_k_i),
                    .valid_i ((pe_row < cfg_m_i) && (pe_col < cfg_n_i)),
                    .sat_en_i(sat_en_i),
                    .result_o(pe_result_w[pe_row][pe_col]),
                    .sat_o   (pe_sat_w[pe_row][pe_col])
                );
            end
        end
    endgenerate

    always @(*) begin
        c_acc_o = '0;
        sat_o = 1'b0;

        for (row = 0; row < ROW_COUNT; row = row + 1) begin
            for (col = 0; col < COL_COUNT; col = col + 1) begin
                c_acc_o[row * ACC_ROW_BITS + col * ACC_ELEM_BITS +: ACC_ELEM_BITS] =
                    pe_result_w[row][col];
                sat_o = sat_o | pe_sat_w[row][col];
            end
        end
    end

endmodule
