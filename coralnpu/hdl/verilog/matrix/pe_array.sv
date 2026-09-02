
/*

目前 PE 数据通路按阵列的最大元素输入位宽参数化。输入总线宽度由阵列行/列数
乘以该最大元素位宽得到；当前默认是 32x32、int8，即每路输入 256 bit。

暂时只支持 INT8 输入，输入至脉动阵列的解码需要额外的输入信号，以分割数据


psum_pre_valid_o: 预先输出倒数第二行的 psum_valid 信号，供外部在 psum_valid_o 还未到达时就知道数据何时有效。
用于从rd中提前读取数据

*/

module pe_array #(
    parameter int                                       MAX_ELEM_WIDTH  = 8     ,
    parameter int                                       PE_ACC_WIDTH    = 32    ,
    parameter int                                       TILE_COLS       = 32    ,
    parameter int                                       TILE_ROWS       = 32
) (
    input  logic                                        clk                     ,
    input  logic                                        rst_n                   ,

    input  logic                                        load_weight_ping_i      ,
    input  logic                                        load_weight_pong_i      ,
    input  logic [TILE_COLS-1:0]                        weight_bank_sel_i       ,
    input  logic [TILE_ROWS * MAX_ELEM_WIDTH -1 : 0]    weight_tile_i           ,
    input  logic [TILE_COLS-1:0]                        psum_top_valid_i        ,
    input  logic [TILE_COLS-1:0]                        act_top_valid_i         ,
    input  logic [TILE_COLS * MAX_ELEM_WIDTH -1 : 0]    act_top_i               ,

    output logic                                        psum_valid_o            ,
    output logic                                        psum_pre_valid_o        ,
    output logic                                        psum_pre2_valid_o       ,
    output logic [TILE_COLS * PE_ACC_WIDTH - 1 : 0]     psum_bottom_o
);

    localparam int PRODUCT_WIDTH = MAX_ELEM_WIDTH * 2;

    logic [MAX_ELEM_WIDTH-1:0]  weight_left_vec     [0:TILE_ROWS-1];
    logic [MAX_ELEM_WIDTH-1:0]  act_top_vec         [0:TILE_COLS-1];
    logic [MAX_ELEM_WIDTH-1:0]  pe_weight_i         [0:TILE_ROWS-1][0:TILE_COLS-1];
    logic [MAX_ELEM_WIDTH-1:0]  pe_weight_o         [0:TILE_ROWS-1][0:TILE_COLS-1];
    logic [MAX_ELEM_WIDTH-1:0]  pe_act_i            [0:TILE_ROWS-1][0:TILE_COLS-1];
    logic [MAX_ELEM_WIDTH-1:0]  pe_act_o            [0:TILE_ROWS-1][0:TILE_COLS-1];
    logic [PE_ACC_WIDTH-1:0]    pe_psum_i           [0:TILE_ROWS-1][0:TILE_COLS-1];
    logic [PE_ACC_WIDTH-1:0]    pe_psum_o           [0:TILE_ROWS-1][0:TILE_COLS-1];
    logic                       pe_act_valid_i      [0:TILE_ROWS-1][0:TILE_COLS-1];
    logic                       pe_act_valid_o      [0:TILE_ROWS-1][0:TILE_COLS-1];
    logic                       pe_psum_valid_i     [0:TILE_ROWS-1][0:TILE_COLS-1];
    logic                       pe_psum_valid_o     [0:TILE_ROWS-1][0:TILE_COLS-1];
    logic                       pe_weight_bank_sel_i[0:TILE_ROWS-1][0:TILE_COLS-1];
    logic                       pe_weight_bank_sel_o[0:TILE_ROWS-1][0:TILE_COLS-1];

    // TODO 当前只支持int8输入,因此这里直接根据 MAX_ELEM_WIDTH 做了硬连线，后续还应根据不同的输入类型做不同的解码逻辑
    genvar pack_weight_row_idx;
    generate
        for (pack_weight_row_idx = 0; pack_weight_row_idx < TILE_ROWS; pack_weight_row_idx = pack_weight_row_idx + 1) begin : gen_pack_weight
            assign weight_left_vec[pack_weight_row_idx] = weight_tile_i[pack_weight_row_idx*MAX_ELEM_WIDTH +: MAX_ELEM_WIDTH];
        end
    endgenerate

    genvar pack_act_col_idx;
    generate
        for (pack_act_col_idx = 0; pack_act_col_idx < TILE_COLS; pack_act_col_idx = pack_act_col_idx + 1) begin : gen_pack_col
            assign act_top_vec[pack_act_col_idx]    = act_top_i[pack_act_col_idx*MAX_ELEM_WIDTH +: MAX_ELEM_WIDTH];
        end
    endgenerate

    // FIR-WS 权重从阵列左侧输入。每向右传播一列，整列权重向上循环一行。
    // 这里的 generate 只生成 PE 之间的固定连线，不包含动态取模或选择逻辑。
    genvar weight_row_idx;
    genvar weight_col_idx;
    generate
        for (weight_row_idx = 0; weight_row_idx < TILE_ROWS; weight_row_idx = weight_row_idx + 1) begin : gen_weight_row
            for (weight_col_idx = 0; weight_col_idx < TILE_COLS; weight_col_idx = weight_col_idx + 1) begin : gen_weight_col
                if (weight_col_idx == 0) begin : gen_weight_left_input
                    assign pe_weight_i[weight_row_idx][weight_col_idx] = weight_left_vec[weight_row_idx];
                end else if (weight_row_idx == TILE_ROWS-1) begin : gen_weight_row_wrap
                    assign pe_weight_i[weight_row_idx][weight_col_idx] = pe_weight_o[0][weight_col_idx-1];
                end else begin : gen_weight_row_shift
                    assign pe_weight_i[weight_row_idx][weight_col_idx] = pe_weight_o[weight_row_idx+1][weight_col_idx-1];
                end
            end
        end
    endgenerate


    always @* begin : gen_act_psum_route
        integer row_idx;
        integer col_idx;
        integer prev_act_col_idx;

        for (row_idx = 0; row_idx < TILE_ROWS; row_idx = row_idx + 1) begin
            for (col_idx = 0; col_idx < TILE_COLS; col_idx = col_idx + 1) begin
                if (row_idx == 0) begin
                    pe_act_i[row_idx][col_idx]        = act_top_vec[col_idx];
                    pe_act_valid_i[row_idx][col_idx]  = act_top_valid_i[col_idx];
                    pe_psum_i[row_idx][col_idx]       = '0;
                    pe_psum_valid_i[row_idx][col_idx] = psum_top_valid_i[col_idx];
                end else begin
                    pe_psum_i[row_idx][col_idx]       = pe_psum_o[row_idx-1][col_idx];
                    pe_psum_valid_i[row_idx][col_idx] = pe_psum_valid_o[row_idx-1][col_idx];

                    if (col_idx == TILE_COLS - 1) begin
                        prev_act_col_idx = 0;
                    end else begin
                        prev_act_col_idx = col_idx + 1;
                    end
                    pe_act_i[row_idx][col_idx]        = pe_act_o[row_idx-1][prev_act_col_idx];
                    pe_act_valid_i[row_idx][col_idx]  = pe_act_valid_o[row_idx-1][prev_act_col_idx];
                end
            end
        end
    end

    always @* begin : gen_weight_bank_sel_route
        integer row_idx;
        integer col_idx;

        for (row_idx = 0; row_idx < TILE_ROWS; row_idx = row_idx + 1) begin
            for (col_idx = 0; col_idx < TILE_COLS; col_idx = col_idx + 1) begin
                if (row_idx == 0)
                    pe_weight_bank_sel_i[row_idx][col_idx] = weight_bank_sel_i[col_idx];
                else
                    pe_weight_bank_sel_i[row_idx][col_idx] = pe_weight_bank_sel_o[row_idx-1][col_idx];
            end
        end
    end

    genvar gen_row_idx;
    genvar gen_col_idx;
    generate
        for (gen_row_idx = 0; gen_row_idx < TILE_ROWS; gen_row_idx = gen_row_idx + 1) begin : gen_row
            for (gen_col_idx = 0; gen_col_idx < TILE_COLS; gen_col_idx = gen_col_idx + 1) begin : gen_col
                pe_ws #(
                    .MAX_ELEM_WIDTH ( MAX_ELEM_WIDTH ),
                    .PE_ACC_WIDTH   ( PE_ACC_WIDTH  )
                ) u_pe_ws (
                    .clk                ( clk ),
                    .rst_n              ( rst_n ),
                    .load_weight_ping_i ( load_weight_ping_i ),
                    .load_weight_pong_i ( load_weight_pong_i ),
                    .weight_i           ( pe_weight_i[gen_row_idx][gen_col_idx] ),
                    .act_valid_i        ( pe_act_valid_i[gen_row_idx][gen_col_idx] ),
                    .psum_valid_i       ( pe_psum_valid_i[gen_row_idx][gen_col_idx] ),
                    .weight_bank_sel_i  ( pe_weight_bank_sel_i[gen_row_idx][gen_col_idx] ),
                    .act_i              ( pe_act_i[gen_row_idx][gen_col_idx] ),
                    .psum_i             ( pe_psum_i[gen_row_idx][gen_col_idx] ),
                    .act_valid_o        ( pe_act_valid_o[gen_row_idx][gen_col_idx] ),
                    .psum_valid_o       ( pe_psum_valid_o[gen_row_idx][gen_col_idx] ),
                    .weight_bank_sel_o  ( pe_weight_bank_sel_o[gen_row_idx][gen_col_idx] ),
                    .weight_o           ( pe_weight_o[gen_row_idx][gen_col_idx] ),
                    .act_o              ( pe_act_o[gen_row_idx][gen_col_idx] ),
                    .psum_o             ( pe_psum_o[gen_row_idx][gen_col_idx] )
                );
            end
        end
    endgenerate

    always @* begin : gen_output_route
        integer out_col_idx;

        psum_valid_o = pe_psum_valid_o[TILE_ROWS-1][0];
        psum_pre_valid_o = pe_psum_valid_o[TILE_ROWS-2][0];
        psum_pre2_valid_o = pe_psum_valid_o[TILE_ROWS-3][0];
        for (out_col_idx = 0; out_col_idx < TILE_COLS; out_col_idx = out_col_idx + 1) begin
            psum_bottom_o[out_col_idx*PE_ACC_WIDTH +: PE_ACC_WIDTH] = pe_psum_o[TILE_ROWS-1][out_col_idx];
        end
    end

endmodule
