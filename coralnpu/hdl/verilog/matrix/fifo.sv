/*
同步 FIFO（单时钟）

用途：
1. 用来缓存控制侧生成的地址/行号队列。
2. `rd_data_o` 直出当前队头数据，便于外部先看到地址，再等数据返回。
3. 真正出队发生在 `rd_en_i` 有效的时钟沿。

说明：
1. 这里只复位读写指针和计数，不去复位整个存储体，这样更接近常见 FIFO 写法。
2. 当前实现不提供额外清空口，默认上一条命令会把 FIFO 自然读空。
3. 空/满判断使用“读写指针 + 翻转位”，不再单独维护 used_count。
4. 当前实现是最基础的同步 FIFO，不带旁路，不带 ready/valid 包装。
*/

module fifo #(
    parameter int DATA_WIDTH = 8,
    parameter int DEPTH      = 8
) (
    input  logic                  clk      ,
    input  logic                  rst_n    ,
    input  logic                  wr_en_i  ,
    input  logic [DATA_WIDTH-1:0] wr_data_i,
    output logic                  full_o   ,
    input  logic                  rd_en_i  ,
    output logic [DATA_WIDTH-1:0] rd_data_o,
    output logic                  empty_o
);

    localparam int ADDR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    logic [ADDR_WIDTH-1:0] wr_addr;
    logic [ADDR_WIDTH-1:0] rd_addr;
    logic                  wr_wrap;
    logic                  rd_wrap;
    logic                  do_write;
    logic                  do_read;
    logic [ADDR_WIDTH-1:0] wr_addr_next;
    logic [ADDR_WIDTH-1:0] rd_addr_next;
    logic                  wr_wrap_next;
    logic                  rd_wrap_next;

    assign empty_o   = (wr_addr == rd_addr) && (wr_wrap == rd_wrap);
    assign full_o    = (wr_addr == rd_addr) && (wr_wrap != rd_wrap);
    assign do_write  = wr_en_i && !full_o;
    assign do_read   = rd_en_i && !empty_o;
    assign rd_data_o = empty_o ? '0 : mem[rd_addr];

    always @* begin
        wr_addr_next = wr_addr;
        wr_wrap_next = wr_wrap;

        if (wr_addr == ADDR_WIDTH'(DEPTH - 1)) begin
            wr_addr_next = '0;
            wr_wrap_next = ~wr_wrap;
        end else begin
            wr_addr_next = wr_addr + ADDR_WIDTH'(1);
            wr_wrap_next = wr_wrap;
        end
    end

    always @* begin
        rd_addr_next = rd_addr;
        rd_wrap_next = rd_wrap;

        if (rd_addr == ADDR_WIDTH'(DEPTH - 1)) begin
            rd_addr_next = '0;
            rd_wrap_next = ~rd_wrap;
        end else begin
            rd_addr_next = rd_addr + ADDR_WIDTH'(1);
            rd_wrap_next = rd_wrap;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_addr <= '0;
            rd_addr <= '0;
            wr_wrap <= 1'b0;
            rd_wrap <= 1'b0;
        end else begin
            if (do_write) begin
                mem[wr_addr] <= wr_data_i;
                wr_addr      <= wr_addr_next;
                wr_wrap      <= wr_wrap_next;
            end

            if (do_read) begin
                rd_addr <= rd_addr_next;
                rd_wrap <= rd_wrap_next;
            end
        end
    end

endmodule
