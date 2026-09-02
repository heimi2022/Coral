`timescale 1 ns / 1 ps

module AXI4_write_ctrl #(
    parameter integer AXI_ID_WIDTH	                    = 1             ,
    parameter integer AXI_ADDR_WIDTH	                = 32            ,
    parameter integer AXI_DATA_WIDTH	                = 512           ,
    parameter integer AXI_AWUSER_WIDTH	                = 0             ,
    parameter integer AXI_WUSER_WIDTH	                = 0             ,
    parameter integer AXI_BUSER_WIDTH	                = 0             ,
    parameter integer TRAN_BYTE_NUM_WIDTH               = 16            ,   // 传输总字节数位宽
    parameter integer SRAM_ADDR_WIDTH                   = 32                // sram 目标基地址位宽
)(
    input                                           clk                         ,
    input                                           rst_n                       ,
// 外部输入信号
    input           [AXI_ADDR_WIDTH      - 1 : 0]   w_target_slave_base_addr_i  ,   // 写基地址输入
    input           [TRAN_BYTE_NUM_WIDTH - 1 : 0]   w_total_byte_num_i          ,   // 写传输总字节数输入
    input                                           w_start_i                   ,   // 写启动信号输入
    input           [AXI_DATA_WIDTH - 1 : 0]        w_data_i                    ,   // 写数据输入
// 输出信号
    output  reg                                     w_busy_o                    ,   // AXI 写忙信号输出
    output  reg     [SRAM_ADDR_WIDTH - 1 : 0]       w_sram_addr_o               ,   // sram 地址输出
    output  wire                                    w_sram_data_request_o       ,   // sram 数据请求输出
    output  reg                                     w_error_o                   ,   // Asserts when ERROR is detected
// AW 信号
    output  wire    [AXI_ID_WIDTH - 1 : 0]          M_AXI_AWID                  ,
    output  wire    [AXI_ADDR_WIDTH - 1 : 0]        M_AXI_AWADDR                ,
    output  wire    [7 : 0]                         M_AXI_AWLEN                 ,
    output  wire    [2 : 0]                         M_AXI_AWSIZE                ,
    output  wire    [1 : 0]                         M_AXI_AWBURST               ,
    output  wire                                    M_AXI_AWLOCK                ,
    output  wire    [3 : 0]                         M_AXI_AWCACHE               ,
    output  wire    [2 : 0]                         M_AXI_AWPROT                ,
    output  wire    [3 : 0]                         M_AXI_AWQOS                 ,
    output  wire    [AXI_AWUSER_WIDTH - 1 : 0]      M_AXI_AWUSER                ,
    output  wire                                    M_AXI_AWVALID               ,
    input   wire                                    M_AXI_AWREADY               ,
// W 信号
    output  wire    [AXI_DATA_WIDTH - 1 : 0]        M_AXI_WDATA                 ,
    output  wire    [AXI_DATA_WIDTH/8 - 1 : 0]      M_AXI_WSTRB                 ,
    output  wire                                    M_AXI_WLAST                 ,
    output  wire    [AXI_WUSER_WIDTH - 1 : 0]       M_AXI_WUSER                 ,
    output  wire                                    M_AXI_WVALID                ,
    input   wire                                    M_AXI_WREADY                ,
// B 信号
    input   wire [AXI_ID_WIDTH - 1 : 0]             M_AXI_BID                   ,
    input   wire [1 : 0]                            M_AXI_BRESP                 ,
    input   wire [AXI_BUSER_WIDTH - 1 : 0]          M_AXI_BUSER                 ,
    input   wire                                    M_AXI_BVALID                ,
    output  wire                                    M_AXI_BREADY                 
);

    // 计算所需的最小位宽
    function integer clogb2 (input integer bit_depth); 
        begin   
            for(clogb2=0; bit_depth>0; clogb2=clogb2+1)    
                bit_depth = bit_depth >> 1;
        end   
    endfunction

    localparam integer AXI_STRB_WIDTH = AXI_DATA_WIDTH/8;
    // 一次突发传输最多传多少字节
    localparam integer MAX_TRANSACTIONS_BYTE_NUM = 256 * AXI_STRB_WIDTH;

    // 传输一个数据的字节数位宽
    localparam integer STRB_LOG2 = clogb2(AXI_STRB_WIDTH-1);

    function [AXI_STRB_WIDTH - 1 : 0] gen_low_strb_mask;
        input [STRB_LOG2 - 1 : 0] active_bytes;
        integer byte_idx;
        begin
            gen_low_strb_mask = 'b0;
            for (byte_idx = 0; byte_idx < AXI_STRB_WIDTH; byte_idx = byte_idx + 1) begin
                if (byte_idx < active_bytes)
                    gen_low_strb_mask[byte_idx] = 1'b1;
            end
        end
    endfunction

// AXI4LITE signals
    //AXI4 internal temp signals
    reg     [AXI_ADDR_WIDTH-1 : 0]      axi_awaddr              ; // 地址偏移量
    reg  	                            axi_awvalid             ;
    reg     [7 : 0]                     axi_awlen               ;
    reg     [AXI_STRB_WIDTH-1 : 0]      axi_wstrb               ;
    reg  	                            axi_wlast               ;
    reg  	                            axi_wvalid              ;
    reg  	                            axi_bready              ;
    reg     [AXI_ADDR_WIDTH - 1 : 0]    w_target_slave_base_addr; // 写基地址寄存器
    // write beat count in a burst
    reg     [7 : 0] 	                write_index             ;

    reg  	                            start_single_burst_write;
    reg  	                            burst_write_active      ;
    reg [TRAN_BYTE_NUM_WIDTH : 0]       byte_remain_num         ;

    wire  	                            write_resp_error        ;     // Interface response error flags
    wire  	                            wnext                   ;     // write data channel ready to accept data
    wire [TRAN_BYTE_NUM_WIDTH : 0]      w_total_byte_num        ;

    reg                                 last_strb_en            ;
    reg [AXI_STRB_WIDTH - 1 : 0]        last_wstrb              ;

    reg                                 start_strb_en           ;
    reg [AXI_STRB_WIDTH - 1 : 0]        start_wstrb             ;

// I/O Connections assignments

//I/O Connections. Write Address (AW)
    assign M_AXI_AWID = 'b0;
    assign M_AXI_AWADDR	= w_target_slave_base_addr + axi_awaddr;
    //
    assign M_AXI_AWLEN = axi_awlen;
    // 传输的一个数据的字节数
    assign M_AXI_AWSIZE	= STRB_LOG2;
    //INCR burst
    assign M_AXI_AWBURST = 2'b01;
    assign M_AXI_AWLOCK	= 1'b0;
    assign M_AXI_AWCACHE = 4'b0010;
    assign M_AXI_AWPROT	= 3'h0;
    assign M_AXI_AWQOS	= 4'h0;
    assign M_AXI_AWUSER	= 'b1;
    assign M_AXI_AWVALID = axi_awvalid;
    
//Write Data(W)
    assign M_AXI_WDATA	= w_data_i;
    //All bursts are complete and aligned in this example
    assign M_AXI_WSTRB	= axi_wstrb;
    assign M_AXI_WLAST	= axi_wlast;
    assign M_AXI_WUSER	= 'b0;
    assign M_AXI_WVALID	= axi_wvalid;
//Write Response (B)
    assign M_AXI_BREADY	= axi_bready;

// 地址对齐
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)
            w_target_slave_base_addr <= 'b0;
        else begin
            if(w_start_i)
                w_target_slave_base_addr <= w_target_slave_base_addr_i - w_target_slave_base_addr_i[STRB_LOG2 - 1 : 0];
            else
                w_target_slave_base_addr <= w_target_slave_base_addr;
        end
    end

// 字节有效信号生成
    // 起始传输字节 掩码 信号生成
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)
            start_strb_en <= 1'b0;
        else begin
            if(w_start_i && w_target_slave_base_addr_i[STRB_LOG2 - 1 : 0] > 0)
                start_strb_en <= 1'b1;
            else if(wnext)
                start_strb_en <= 1'b0;
            else
                start_strb_en <= start_strb_en;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)
            start_wstrb <= 1'b0;
        else begin
            if(w_start_i) begin
                if(w_target_slave_base_addr_i[STRB_LOG2 - 1 : 0] > 0)
                    start_wstrb <= {AXI_STRB_WIDTH{1'b1}} << w_target_slave_base_addr_i[STRB_LOG2 - 1 : 0];
                else
                    start_wstrb <= 0;
            end
            else
                start_wstrb <= start_wstrb;
        end
    end

    // 末尾传输字节 掩码 信号生成
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)
            last_strb_en <= 1'b0;
        else begin
            if(w_start_i)
                if(w_total_byte_num[STRB_LOG2 - 1 : 0] > 0)
                    last_strb_en <= 1'b1;
                else
                    last_strb_en <= 1'b0;
            else
                last_strb_en <= last_strb_en;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)
            last_wstrb <= 1'b0;
        else begin
            if(w_start_i) begin
                if(w_total_byte_num[STRB_LOG2 - 1 : 0] > 0)
                    last_wstrb <= gen_low_strb_mask(w_total_byte_num[STRB_LOG2 - 1 : 0]);
                else
                    last_wstrb <= 0;
            end
            else
                last_wstrb <= last_wstrb;
        end
    end

// 数据字节数预处理
    
    assign w_total_byte_num = w_total_byte_num_i + w_target_slave_base_addr_i[STRB_LOG2 - 1 : 0];
    // 计算 剩余待传输字节数
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)
            byte_remain_num <= 1'b0;
        else begin
            if(w_start_i) begin
                byte_remain_num <= w_total_byte_num;  
            end
            else if (M_AXI_AWREADY && axi_awvalid) begin
                if(byte_remain_num >= MAX_TRANSACTIONS_BYTE_NUM)
                    byte_remain_num <= byte_remain_num - MAX_TRANSACTIONS_BYTE_NUM;
                else
                    byte_remain_num <= 0;
            end
            else begin
                byte_remain_num <= byte_remain_num;
            end
        end
    end

// sram 相关信号输出
    // sram 地址偏移
    always @(posedge clk or negedge rst_n) begin 
        if(!rst_n)
            w_sram_addr_o <= 1'b0;
        else begin
            if(w_start_i)
                w_sram_addr_o <= 1'b0;
            else if (w_sram_data_request_o)    
                w_sram_addr_o <= w_sram_addr_o + 1'd1;
            else
                w_sram_addr_o <= w_sram_addr_o;
        end
    end

    // sram 数据请求信号生成
    assign w_sram_data_request_o = (M_AXI_AWREADY && axi_awvalid) || (wnext && !axi_wlast);

// 突发写传输控制信号生成
    // start_single_burst_write 信号用于启动一个突发写事务
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) 
            start_single_burst_write <= 1'b0;
        else begin
            if(w_busy_o) begin
                if (~axi_awvalid && ~start_single_burst_write && ~burst_write_active)
                    start_single_burst_write <= 1'b1;
                else
                    start_single_burst_write <= 1'b0; //Negate to generate a pulse
            end
            else
                start_single_burst_write <= 1'b0;
        end
    end
    
    
    // burst_write_active signal is asserted when there is a burst write transaction
    always @(posedge clk or negedge rst_n)begin
        if (!rst_n)
            burst_write_active <= 1'b0;
        else begin
            if(w_start_i)
                burst_write_active <= 1'b0;
            else if (start_single_burst_write)
                burst_write_active <= 1'b1;
            else if (M_AXI_BVALID && axi_bready)
                burst_write_active <= 1'b0;  
        end
    end
    
//--------------------
//Write Address Channel
//--------------------

    // 写突发长度计算 突发长度 = axi_awlen + 1
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) 
            axi_awlen <= 1'b0;
        else begin
            if(start_single_burst_write) begin
                if(byte_remain_num >= MAX_TRANSACTIONS_BYTE_NUM)
                    axi_awlen <= 8'd255;
                else begin
                    if(byte_remain_num[STRB_LOG2 - 1 : 0] > 0)
                        axi_awlen <= (byte_remain_num >> STRB_LOG2);
                    else
                        axi_awlen <= (byte_remain_num >> STRB_LOG2) - 1;
                end
            end
            else
                axi_awlen <= axi_awlen;
        end
    end

    // 写地址有效信号生成
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_awvalid <= 1'b0;
        end
        else begin
            if (~axi_awvalid && start_single_burst_write)
                axi_awvalid <= 1'b1;
            else if (M_AXI_AWREADY && axi_awvalid)
                axi_awvalid <= 1'b0;
            else  
                axi_awvalid <= axi_awvalid; 
        end
    end   
           
           
    // 写地址生成
    always @(posedge clk or negedge rst_n)begin
        if (!rst_n)
            axi_awaddr <= 1'b0;
        else begin
            if(w_start_i)
                axi_awaddr <= 1'b0;
            else if (M_AXI_AWREADY && axi_awvalid)
                axi_awaddr <= axi_awaddr + MAX_TRANSACTIONS_BYTE_NUM;    
            else
                axi_awaddr <= axi_awaddr;
        end
    end

    // 写掩码信号生成
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)
            axi_wstrb <= 1'b0;
        else begin
            if(M_AXI_AWREADY && axi_awvalid) begin
                if(start_strb_en)
                    axi_wstrb <= start_wstrb;
                else if(axi_awlen == 1'b0 && last_strb_en)
                    axi_wstrb <= last_wstrb;
                else
                    axi_wstrb <= {(AXI_STRB_WIDTH){1'b1}};
            end
            else if(wnext) begin
                if((write_index == axi_awlen-1'b1 && axi_awlen >= 1'b1) && last_strb_en && byte_remain_num == 1'b0)
                    axi_wstrb <= last_wstrb;
                else
                    axi_wstrb <= {(AXI_STRB_WIDTH){1'b1}};
            end
            else
                axi_wstrb <= axi_wstrb;
        end
    end  


//--------------------
//Write Data Channel
//--------------------
    assign wnext = M_AXI_WREADY & axi_wvalid;
    
    // AW and W are independent AXI channels.  Launch the first W beat with
    // AWVALID; waiting for AWREADY here deadlocks frontends that only accept
    // an address after write data is already available.
    always @(posedge clk or negedge rst_n) begin 
        if (!rst_n)
            axi_wvalid <= 1'b0;
        else begin
            if (~axi_wvalid && start_single_burst_write)
                axi_wvalid <= 1'b1;
            else if (wnext && axi_wlast)
                axi_wvalid <= 1'b0;   
            else
                axi_wvalid <= axi_wvalid;
        end
    end

    //WLAST generation on the MSB of a counter underflow    
    // WVALID logic, similar to the axi_awvalid always block above
    always @(posedge clk or negedge rst_n) begin 
        if (!rst_n) begin
            axi_wlast <= 1'b0;
        end
        else begin
            if(w_start_i == 1'b1)
                axi_wlast <= 1'b0;
            else if (start_single_burst_write)
                axi_wlast <= (byte_remain_num <= AXI_STRB_WIDTH);
            else if ((write_index == axi_awlen-1 && axi_awlen >= 1) && wnext)
                axi_wlast <= 1'b1;
            else if (wnext)
                axi_wlast <= 1'b0;
            else
                axi_wlast <= axi_wlast;
        end
    end


    // 一次突发，数据传输计数器
    always @(posedge clk or negedge rst_n) begin 
        if (!rst_n) begin
            write_index <= 1'b0;   
        end
        else begin
            if(w_start_i == 1'b1 || start_single_burst_write == 1'b1)
                write_index <= 1'b0;
            else if (wnext && (write_index != axi_awlen))
                write_index <= write_index + 1'b1;  
            else
                write_index <= write_index;
        end
    end   

//----------------------------
//Write Response (B) Channel
//----------------------------
    always @(posedge clk or negedge rst_n) begin    
        if (!rst_n) begin
            axi_bready <= 1'b0;  
        end
        else begin
            if(w_start_i == 1'b1)
                axi_bready <= 1'b0;
            else if (axi_wlast && ~axi_bready) 
                axi_bready <= 1'b1;  
            else if (axi_bready && M_AXI_BVALID) 
                axi_bready <= 1'b0;  
            else   
                axi_bready <= axi_bready;
        end
    end

// 写忙 及 写错误信号生成
    //Flag any write response errors
    assign write_resp_error = axi_bready & M_AXI_BVALID & M_AXI_BRESP[1]; 

    // AXI 写错误信号生成
    always @(posedge clk or negedge rst_n) begin 
        if (!rst_n) begin  
            w_error_o <= 1'b0;
        end
        else begin
            if(w_start_i)
                w_error_o <= 1'b0;
            else if (write_resp_error)  
                w_error_o <= 1'b1;
            else
                w_error_o <= w_error_o;
        end
    end   

    // AXI 写忙信号生成
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)
            w_busy_o <= 1'b0;
        else begin
            if(w_start_i)
                w_busy_o <= 1'b1;
            else if (M_AXI_BVALID && byte_remain_num == 1'b0 && axi_bready)
                w_busy_o <= 1'b0;
            else
                w_busy_o <= w_busy_o;
        end
    end

endmodule
