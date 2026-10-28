/*
读通道支持非对齐传输
一次ar 握手 发射一个 burst 请求
支持 outstanding, 暂不支持 乱序 和 交织

由于非对齐传输，本模块在数据返回时同步给出 burst 起始 offset 和本拍有效字节数，
上层据此完成跨 beat 拼接。

*/


`timescale 1 ns / 1 ps

module AxiReadBurstCtrl #(
    parameter integer AXI_ID_WIDTH	                    = 1             ,
    parameter integer AXI_ADDR_WIDTH	                = 32            ,
    parameter integer AXI_DATA_WIDTH	                = 512           ,
    parameter integer AXI_ARUSER_WIDTH	                = 0             ,
    parameter integer AXI_RUSER_WIDTH	                = 0             ,
    parameter integer READ_OUTSTANDING_DEPTH            = 4             ,
    parameter integer BURST_BYTE_NUM_WIDTH              = 13             // 单个 burst 请求的有效字节数字段位宽
)(
// 时钟复位
    input                                           clk                         ,
    input                                           rst_n                       ,
// 输入信号
    input           [AXI_ADDR_WIDTH - 1 : 0]        burst_addr_i                ,   // 单个 burst 请求的起始地址
    input           [BURST_BYTE_NUM_WIDTH - 1 : 0]  burst_byte_num_i            ,   // 单个 burst 请求的有效字节数
    input                                           burst_valid_i               ,   // 单个 burst 请求有效
    input                                           burst_cmd_last_i            ,   // 本 burst 是所属 LOAD 的最后一个
    input                                           r_pause_i                   ,   // 上层要求当前拍后暂停继续接收 R beat
// 输出信号
    output  wire                                    r_req_busy_o                ,   // 当前不能再接收新的 burst 请求
    output  reg                                     r_burst_busy_o              ,   // 当前 burst 仍在执行
    output  reg                                     r_beat_valid_o              ,   // 当前返回 beat 有效
    output  reg                                     r_beat_first_o              ,   // 当前返回 beat 是本 burst 首拍
    output  reg                                     r_beat_last_o               ,   // 当前返回 beat 是本 burst 尾拍
    output  reg                                     r_cmd_last_o                ,   // 当前有效 beat 是所属 LOAD 的尾拍
    output  reg     [$clog2(AXI_DATA_WIDTH/8)-1:0]  r_burst_start_offset_o      ,   // 当前 burst 起始地址在 beat 内的字节偏移
    output  reg     [$clog2(AXI_DATA_WIDTH/8):0]    r_beat_byte_count_o         ,   // 当前返回 beat 的有效字节数
    output  wire    [AXI_DATA_WIDTH - 1 : 0]        r_beat_data_o               ,   // 当前返回 beat 的数据
    output  reg                                     r_burst_done_error_o        ,   // 当前 burst 完成时是否检测到错误
// AR 信号
    output  wire    [AXI_ID_WIDTH - 1 : 0]          M_AXI_ARID                  ,
    output  wire    [AXI_ADDR_WIDTH - 1 : 0]        M_AXI_ARADDR                ,
    output  wire    [7 : 0]                         M_AXI_ARLEN                 ,
    output  wire    [2 : 0]                         M_AXI_ARSIZE                ,
    output  wire    [1 : 0]                         M_AXI_ARBURST               ,
    output  wire                                    M_AXI_ARLOCK                ,
    output  wire    [3 : 0]                         M_AXI_ARCACHE               ,
    output  wire    [2 : 0]                         M_AXI_ARPROT                ,
    output  wire    [3 : 0]                         M_AXI_ARQOS                 ,
    output  wire    [AXI_ARUSER_WIDTH - 1 : 0]      M_AXI_ARUSER                ,
    output  wire                                    M_AXI_ARVALID               ,
    input   wire                                    M_AXI_ARREADY               ,
// R 信号
    input   wire    [AXI_ID_WIDTH - 1 : 0]          M_AXI_RID                   ,
    input   wire    [AXI_DATA_WIDTH - 1 : 0]        M_AXI_RDATA                 ,
    input   wire    [1 : 0]                         M_AXI_RRESP                 ,
    input   wire                                    M_AXI_RLAST                 ,
    input   wire    [AXI_RUSER_WIDTH - 1 : 0]       M_AXI_RUSER                 ,
    input   wire                                    M_AXI_RVALID                ,
    output  wire                                    M_AXI_RREADY                
);

    localparam integer AXI_BEAT_BYTES  = AXI_DATA_WIDTH / 8; // 64

    // 传输一个数据的字节数位宽
    localparam integer AXI_BEAT_LG2 = $clog2(AXI_BEAT_BYTES);  // 6
    localparam integer AXI_BEAT_COUNT_W = AXI_BEAT_LG2 + 1;    // 7，可表达 64B
    localparam integer READ_META_WIDTH = 1 + AXI_BEAT_LG2 + AXI_BEAT_COUNT_W;


// AXI4LITE signals
    reg     [AXI_DATA_WIDTH - 1 : 0]        axi_rdata               ;
    reg                                     issue_valid             ;
    reg     [AXI_ADDR_WIDTH - 1 : 0]        issue_addr_aligned      ;
    reg     [7 : 0]                         issue_arlen             ;
    reg     [AXI_BEAT_LG2 - 1 : 0]          issue_start_offset      ;
    reg     [AXI_BEAT_COUNT_W - 1 : 0]      issue_end_offset        ;
    reg                                     resp_nonfirst_beat_n      ;
    reg                                     resp_error_seen         ;
    wire  	                                read_resp_error         ;        // Interface response error flags
    wire  	                                r_fire_w                ;
    wire  	                                ar_fire_w               ;
    wire  	                                r_last_fire_w           ;
    wire  	                                req_accept_w            ;
    wire  	                                req_ready_w             ;
    wire    [AXI_BEAT_LG2 - 1 : 0]          start_offset_w          ;
    wire    [BURST_BYTE_NUM_WIDTH : 0]      burst_total_byte_num_w  ;
    wire    [AXI_BEAT_COUNT_W - 1 : 0]      end_offset_w            ;
    wire    [7 : 0]                         burst_arlen_w           ;
    wire    [READ_META_WIDTH - 1 : 0]        meta_wr_data_w          ;
    wire    [READ_META_WIDTH - 1 : 0]        meta_rd_data_w          ;
    wire                                    meta_fifo_full_w        ;
    wire                                    meta_fifo_empty_w       ;
    wire                                    meta_push_w             ;
    wire                                    meta_pop_w              ;
    wire    [AXI_BEAT_LG2 - 1 : 0]          resp_start_offset_w     ;
    wire    [AXI_BEAT_COUNT_W - 1 : 0]      resp_end_offset_w       ;
    wire                                    resp_cmd_last_w         ;

// I/O Connections assignments

//Read Address (AR)
    assign M_AXI_ARID	    = 'b0           ;
    assign M_AXI_ARSIZE	    = AXI_BEAT_LG2  ;
    assign M_AXI_ARBURST	= 2'b01;  // INCR
    assign M_AXI_ARLOCK	    = 1'b0;
    assign M_AXI_ARCACHE	= 4'b0010;
    assign M_AXI_ARPROT	    = 3'h0;
    assign M_AXI_ARQOS	    = 4'h0;
    assign M_AXI_ARUSER	    = 'b1;
    
//Read and Read Response (R)
    assign M_AXI_RREADY	= !meta_fifo_empty_w && !r_pause_i;
    assign r_fire_w = M_AXI_RVALID && M_AXI_RREADY;
    assign r_last_fire_w = r_fire_w && M_AXI_RLAST;

//----------------------------
//Read Address Channel
//----------------------------

    assign ar_fire_w = M_AXI_ARVALID && M_AXI_ARREADY;

    // 可接收下一条burst请求
    assign req_ready_w =
        (!issue_valid || ar_fire_w) &&
        !meta_fifo_full_w;
    assign r_req_busy_o = !req_ready_w;
    // 接收burst请求成功
    assign req_accept_w = burst_valid_i && req_ready_w;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            issue_valid <= 1'b0;
        end else begin
            if (req_accept_w) begin
                issue_valid <= 1'b1;
            end else if (ar_fire_w) begin
                issue_valid <= 1'b0;
            end
        end
    end
    assign M_AXI_ARVALID = issue_valid;

    always @(posedge clk) begin
        if (req_accept_w)
            issue_addr_aligned <= {burst_addr_i[AXI_ADDR_WIDTH - 1 : AXI_BEAT_LG2], {AXI_BEAT_LG2{1'b0}}};
    end
    assign M_AXI_ARADDR = issue_addr_aligned;

    // 非对齐 burst 的首拍和尾拍都可能只使用一部分字节。
    // 这里先算出：
    // - start_offset_w      : 起始地址在 beat 内的 byte 偏移
    // - burst_total_byte_num_w : 从对齐地址起实际覆盖的总字节数
    // - burst_arlen_w       : 本次单 burst 对应的 AXI ARLEN
    assign start_offset_w = burst_addr_i[AXI_BEAT_LG2-1:0];
    assign burst_total_byte_num_w = burst_byte_num_i + start_offset_w;
    // end_offset_w 表示尾拍有效区间的右开边界。值 64 表示整拍有效，
    // 避免6位余数中的 0 同时承担“0字节”和“64字节”两种语义。
    assign end_offset_w =
        (burst_total_byte_num_w[AXI_BEAT_LG2-1:0] == 0) ?
        AXI_BEAT_BYTES :
        {1'b0, burst_total_byte_num_w[AXI_BEAT_LG2-1:0]};

    always @(posedge clk) begin
        if (req_accept_w) begin
            issue_start_offset <= start_offset_w;
            issue_end_offset <= end_offset_w;
        end
    end

    assign burst_arlen_w = (burst_total_byte_num_w - 1'b1) >> AXI_BEAT_LG2;
    always @(posedge clk) begin
        if (req_accept_w)
            issue_arlen <= burst_arlen_w;
    end
    assign M_AXI_ARLEN = issue_arlen;

    // FIFO 记录的是“已经被上层接受的 burst”，而不是仅记录 AR 已握手的 burst。
    // 这样 issue_valid 中尚未发到 AXI 的那一条也占用 FIFO 空间，避免
    // issue buffer + metadata FIFO 形成额外的一条隐含 outstanding。
    assign meta_wr_data_w = { burst_cmd_last_i, start_offset_w, end_offset_w };
    assign meta_push_w = req_accept_w;
    assign meta_pop_w = r_last_fire_w;
    assign resp_start_offset_w = meta_rd_data_w[AXI_BEAT_COUNT_W +: AXI_BEAT_LG2];
    assign resp_end_offset_w = meta_rd_data_w[AXI_BEAT_COUNT_W - 1 : 0];
    assign resp_cmd_last_w = meta_rd_data_w[READ_META_WIDTH - 1];

    fifo #(
        .DATA_WIDTH ( READ_META_WIDTH          ),
        .DEPTH      ( READ_OUTSTANDING_DEPTH  )
    ) u_read_meta_fifo (
        .clk       ( clk              ),
        .rst_n     ( rst_n            ),
        .wr_en_i   ( meta_push_w      ),
        .wr_data_i ( meta_wr_data_w   ),
        .full_o    ( meta_fifo_full_w ),
        .rd_en_i   ( meta_pop_w       ),
        .rd_data_o ( meta_rd_data_w   ),
        .empty_o   ( meta_fifo_empty_w )
    );

//--------------------------------
//Read Data (and Response) Channel
//--------------------------------

    // 当前响应流只需要区分“是不是队头 burst 的第一拍”，
    // 最后一拍直接由 RLAST 给出，所以这里用 1bit 状态位即可。
    // resp_nonfirst_beat_n:
    // 0 = 当前拍是首拍
    // 1 = 当前拍不是首拍
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            resp_nonfirst_beat_n <= 1'b0;
        else if (r_fire_w) begin
            if (M_AXI_RLAST)
                resp_nonfirst_beat_n <= 1'b0;
            else
                resp_nonfirst_beat_n <= 1'b1;
        end
    end
           
//----------------------------------
// error register
//----------------------------------
    // 响应错误按“当前响应队头 burst”聚合：
    // 1. 当前 burst 返回期间任何一个 beat 返回错误响应后保持为 1
    // 2. 到该 burst 的最后一个 beat 返回时，通过 r_burst_done_error_o 给上层一个结果脉冲
    // 3. 下一个 burst 开始返回前自动清零
    // Flag any read response errors
    assign read_resp_error = r_fire_w & M_AXI_RRESP[1];  
    always @(posedge clk or negedge rst_n) begin 
        if (!rst_n) 
            resp_error_seen <= 1'b0;
        else if (r_last_fire_w)
            resp_error_seen <= 1'b0;
        else if (read_resp_error)
            resp_error_seen <= 1'b1;
    end

//--------------------------------
// beat 输出
//--------------------------------

    // beat 数据输出
    assign r_beat_data_o = axi_rdata;
    always @(posedge clk) begin
        if (r_fire_w)
            axi_rdata <= M_AXI_RDATA;
    end

    always @(posedge clk) begin
        r_beat_valid_o <= r_fire_w;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            r_cmd_last_o <= 1'b0;
        else
            r_cmd_last_o <= r_last_fire_w && resp_cmd_last_w;
    end

    always @(posedge clk) begin
        r_burst_done_error_o <= r_last_fire_w && (resp_error_seen || read_resp_error);
    end

    // 根据当前 beat 在 burst 中的位置输出有效字节数：
    // - 单拍 burst：end_offset - start_offset
    // - 多拍首拍：AXI_BEAT_BYTES - start_offset
    // - 多拍尾拍：end_offset
    // - 中间拍：AXI_BEAT_BYTES
    always @(posedge clk) begin
        if (r_fire_w) begin
            if (!resp_nonfirst_beat_n && r_last_fire_w)  //第一拍也是最后一拍
                r_beat_byte_count_o <=
                    resp_end_offset_w - {1'b0, resp_start_offset_w};
            else if (!resp_nonfirst_beat_n) //第一拍不是最后一拍
                r_beat_byte_count_o <= AXI_BEAT_BYTES - {1'b0, resp_start_offset_w};
            else if (r_last_fire_w)   //最后一拍
                r_beat_byte_count_o <= resp_end_offset_w;
            else
                r_beat_byte_count_o <= AXI_BEAT_BYTES;
        end
    end

    always @(posedge clk) begin
        if (r_fire_w) begin
            r_beat_first_o <= !resp_nonfirst_beat_n;
            r_beat_last_o <= r_last_fire_w;
            r_burst_start_offset_o <= resp_start_offset_w;
        end
    end

    // 只要还有待发请求或者 metadata FIFO 中仍有在途 burst，就视为读事务仍在执行。
    assign r_burst_busy_o = issue_valid || !meta_fifo_empty_w;
    
endmodule
