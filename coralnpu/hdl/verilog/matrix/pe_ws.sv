
/* 
    对应的psum_valid_i 和 act_valid_i 一定是同一周期内过来的，
    但不同n,k配置下，会出现二缺一的情况，此时传递对应值即可
*/
module pe_ws #(
    parameter                               ELEM_WIDTH        = 16  ,
    parameter                               PE_ACC_WIDTH      = 48   
) (
    input  logic clk                                                ,
    input  logic rst_n                                              ,

    input  logic                            load_weight_ping_i      ,
    input  logic                            load_weight_pong_i      ,
    input  logic signed [ELEM_WIDTH-1:0]    weight_i                ,

    input  logic                            act_valid_i             ,
    input  logic                            psum_valid_i            ,
    input  logic                            weight_bank_sel_i       ,
    input  logic signed [ELEM_WIDTH-1:0]    act_i                   ,
    input  logic signed [PE_ACC_WIDTH-1:0]  psum_i                  ,

    output logic                            act_valid_o             ,
    output logic                            psum_valid_o            ,
    output logic                            weight_bank_sel_o       ,
    output logic signed [ELEM_WIDTH-1:0]    weight_o                ,
    output logic signed [ELEM_WIDTH-1:0]    act_o                   ,
    output logic signed [PE_ACC_WIDTH-1:0]  psum_o                   
);

    localparam integer PRODUCT_WIDTH = 2 * ELEM_WIDTH; 

    // Ping-pong weight banks for WS dataflow.
    // weight_bank_sel_i = 1'b0 selects ping, 1'b1 selects pong.
    logic signed [ELEM_WIDTH-1:0] weight_ping;
    logic signed [ELEM_WIDTH-1:0] weight_pong;
    logic signed [ELEM_WIDTH-1:0] weight_sel;
    logic signed [ELEM_WIDTH-1:0] act_masked;
    logic signed [PRODUCT_WIDTH-1:0] product;
    logic signed [PE_ACC_WIDTH-1:0] product_ext;

    assign weight_sel = weight_bank_sel_i ? weight_pong : weight_ping;
    assign act_masked = act_i & {ELEM_WIDTH{act_valid_i}};
    assign product = act_masked * weight_sel;
    assign product_ext = {{(PE_ACC_WIDTH - PRODUCT_WIDTH){product[PRODUCT_WIDTH-1]}}, product};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_ping <= '0;
        end 
        else begin
            if (load_weight_ping_i)
                weight_ping <= weight_i;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_pong <= '0;
        end 
        else begin
            if (load_weight_pong_i) 
                weight_pong <= weight_i;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_valid_o <= 1'b0;
        end 
        else begin
            act_valid_o <= act_valid_i;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            psum_valid_o <= 1'b0;
        end 
        else begin
            psum_valid_o <= psum_valid_i;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_bank_sel_o <= 1'b0;
        end 
        else begin
            weight_bank_sel_o <= weight_bank_sel_i;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_o <= '0;
        end 
        else begin
            if (load_weight_ping_i || load_weight_pong_i)
                weight_o <= weight_i;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_o <= '0;
        end 
        else begin
            if (act_valid_i) 
                act_o <= act_i;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            psum_o <= '0;
        end 
        else begin
            if (psum_valid_i) 
                psum_o <= psum_i + product_ext;
        end
    end

endmodule
