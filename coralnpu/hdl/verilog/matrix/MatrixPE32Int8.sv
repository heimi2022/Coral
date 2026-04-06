module MatrixPE32Int8 (
    input  logic [255:0] a_vec_i,
    input  logic [255:0] b_vec_i,
    input  logic [31:0]  acc_i,
    input  logic [31:0]  cfg_k_i,
    input  logic         valid_i,
    input  logic         sat_en_i,
    output logic [31:0]  result_o,
    output logic         sat_o
);

    localparam integer LANE_COUNT = 32;
    localparam signed [32:0] INT32_MAX_33 = 33'sd2147483647;
    localparam signed [32:0] INT32_MIN_33 = -33'sd2147483648;

    logic signed [15:0] prod_l0_w [0:LANE_COUNT-1];
    logic signed [16:0] sum_l1_w  [0:15];
    logic signed [17:0] sum_l2_w  [0:7];
    logic signed [18:0] sum_l3_w  [0:3];
    logic signed [19:0] sum_l4_w  [0:1];
    logic signed [20:0] dot_sum_w;
    logic signed [32:0] acc_sum_w;

    genvar lane;

    generate
        for (lane = 0; lane < LANE_COUNT; lane = lane + 1) begin : gen_mul_lane
            assign prod_l0_w[lane] = (lane < cfg_k_i) ?
                ($signed(a_vec_i[lane * 8 +: 8]) * $signed(b_vec_i[lane * 8 +: 8])) :
                16'sd0;
        end

        for (lane = 0; lane < 16; lane = lane + 1) begin : gen_sum_l1
            assign sum_l1_w[lane] = prod_l0_w[2 * lane] + prod_l0_w[2 * lane + 1];
        end

        for (lane = 0; lane < 8; lane = lane + 1) begin : gen_sum_l2
            assign sum_l2_w[lane] = sum_l1_w[2 * lane] + sum_l1_w[2 * lane + 1];
        end

        for (lane = 0; lane < 4; lane = lane + 1) begin : gen_sum_l3
            assign sum_l3_w[lane] = sum_l2_w[2 * lane] + sum_l2_w[2 * lane + 1];
        end

        for (lane = 0; lane < 2; lane = lane + 1) begin : gen_sum_l4
            assign sum_l4_w[lane] = sum_l3_w[2 * lane] + sum_l3_w[2 * lane + 1];
        end
    endgenerate

    assign dot_sum_w = sum_l4_w[0] + sum_l4_w[1];
    assign acc_sum_w = {{12{dot_sum_w[20]}}, dot_sum_w} + {acc_i[31], acc_i};

    always @(*) begin
        result_o = '0;
        sat_o = 1'b0;

        if (valid_i) begin
            if (sat_en_i && (acc_sum_w > INT32_MAX_33)) begin
                result_o = 32'sh7fff_ffff;
                sat_o = 1'b1;
            end else if (sat_en_i && (acc_sum_w < INT32_MIN_33)) begin
                result_o = 32'sh8000_0000;
                sat_o = 1'b1;
            end else begin
                result_o = acc_sum_w[31:0];
            end
        end
    end

endmodule
