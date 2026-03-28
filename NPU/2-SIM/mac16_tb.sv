`timescale 1ps / 1ps

module mac16_tb;

    parameter CLK_PERIOD = 20; // 1.5GHz -> 666.67ps

    reg         clk;
    reg         rst_n;
    reg         mode;
    wire         inA;
    wire         inB;
    wire        sum;
    wire        carry;
    wire        out_ready;
    wire [23:0] out;

    reg A_in;
    reg B_in;
    reg [23:0] prev_product; // 保存上一次的乘积 (用于mode 0)
    reg [23:0] acc_sum;      // 保存累加结果 (用于mode 1)

    // 期望结果队列 (Scoreboard FIFO)
    // logic [23:0] expected_queue [$];
    logic [24:0] expected_queue [$];
    reg in_ready;

    // 实例化被测模块 (DUT)
    mac16 dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .mode      (mode),
        .inA       (inA),
        .inB       (inB),
        .in_ready  (in_ready),
        .sum       (sum),
        .carry     (carry),
        .out_ready (out_ready),
        .out       (out)
    );

    // 时钟产生
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    assign inA = A_in;
    assign inB = B_in;

    // 测试流程
    initial begin
        //$set_toggle_region(mac16_tb.dut);
        rst_n = 0;
        mode  = 0;
        A_in = 0;
        B_in = 0;
        prev_product = 24'd0;
        acc_sum      = 24'b0;
        in_ready     = 1'b0;

        #(CLK_PERIOD * 2);
        rst_n = 1;
        //$toggle_start();
        //$display("--- Start recording SAIF ---");

        send_serial_data(16'd14, 16'd71); 
        send_serial_data(16'd8, 16'd30);
        send_serial_data(16'd14, 16'd71);
        @(negedge clk);
        mode = 1;
        acc_sum = 24'd0;
        send_serial_data(16'd116, 16'd828);
        send_serial_data(16'd1546, 16'd1152);
        send_serial_data(16'd20698, 16'd728);



        repeat(50) @(posedge clk);
        $display("========== 测试结束 ==========\n");
        $finish;
        // 4. 停止记录
        // $toggle_stop();
        // $display("--- Stop recording SAIF ---");
        // $toggle_report("rtl_sim.saif", 1.0e-9, mac16_tb.dut);




        $finish;
    end

    // // 任务：模拟串行发送数据
    // task send_serial_data(input [15:0] dataA, input [15:0] dataB);
    //     integer i;
    //     begin
    //         for (i = 15; i >= 0; i = i - 1) begin
    //             A_in <= dataA[i];
    //             B_in <= dataB[i];
    //             @(posedge clk);
    //         end
    //             A_in <= 1'b0;
    //             B_in <= 1'b0;
    //         repeat(5) @(posedge clk); 
    //     end
    // endtask

    task send_serial_data(input [15:0] dataA, input [15:0] dataB);
        integer i;
        reg [23:0] current_p;
        reg [23:0] expected_val;
        begin
            @(posedge clk);
            // 1. 计算当前真实乘积 (注意：16x16最大是32位，这里截断为24位匹配你的输出)
            current_p = (dataA * dataB) & 24'hFFFFFF;

            // 2. 根据 Mode 计算预期结果
            if (mode == 0) begin
                expected_val = (current_p + prev_product) & 24'hFFFFFF;
                prev_product = current_p; // 更新历史乘积
            end else begin
                acc_sum = (acc_sum + current_p) & 24'hFFFFFF;
                expected_val = acc_sum;
            end
            
            // 3. 将预期结果压入队列，等待 Checker 比对
            expected_queue.push_back({mode, expected_val});

            // 4. 驱动硬件输入 (MSB 先进)
            for (i = 15; i >= 0; i = i - 1) begin
                if (i == 15) begin
                    in_ready <= 1'b1;
                end else begin
                    in_ready <= 1'b0;
                end

                A_in <= dataA[i];
                B_in <= dataB[i];
                @(posedge clk);
              end
                A_in <= 1'b0;
                B_in <= 1'b0;
            repeat(5) @(posedge clk); 
        end
    endtask


   // ----- 支持 MSB 先出且连续输出的自动检查器 (Checker) -----
    initial begin
        reg [23:0] actual_val;
        reg [23:0] exp_val;
        integer k;

        forever begin
            @(posedge clk); // 等待时钟上升沿
            
            // 只要 out_ready 为高，就认为当前拍是 24 位数据的第 1 拍
            if (out_ready === 1'b1) begin 
                actual_val = 24'd0;
                
                // 连续抓取 24 拍
                for (k = 0; k < 24; k = k + 1) begin
                    
                    // 【核心修改点】：改为 MSB 高位先出 
                    actual_val[23 - k] = sum; 
                    
                    // 前 23 拍需要等下一个时钟沿，第 24 拍抓完后不等待，直接比对！
                    if (k < 23) begin
                        @(posedge clk);
                    end
                end
                
                // 立即进行比对
                if (expected_queue.size() > 0) begin
                    reg exp_mode;
                    {exp_mode,exp_val} = expected_queue.pop_front();
                    
                    // 调试小技巧：同时打印十进制 (%0d) 和十六进制 (%h)，方便排查错位
                    if (actual_val === exp_val) begin
                        $display("[PASS] @%0t | Mode: %b | 期望: %0d (0x%h), 实际: %0d (0x%h)", 
                                 $time, exp_mode, exp_val, exp_val, actual_val, actual_val);
                    end else begin
                        $display("[FAIL] @%0t | Mode: %b | 期望: %0d (0x%h), 实际: %0d (0x%h)  <--- 错误！", 
                                 $time, exp_mode, exp_val, exp_val, actual_val, actual_val);
                    end
                end else begin
                    $display("[ERROR] @%0t 硬件输出了数据，但参考队列 (expected_queue) 为空！", $time);
                end
                
            end
        end
    end



    initial begin
        $fsdbDumpfile("mac16_tb.fsdb");
        $fsdbDumpvars(0, mac16_tb);
        $fsdbDumpMDA();
    end

    initial begin
        $dumpfile("mac_serial.vcd");
        $dumpvars(0, mac16_tb);
    end

endmodule


