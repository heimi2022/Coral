`timescale 1ns/1ps

module pe_stream_boundary_tb;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0;
    logic cmd_valid = 0;
    wire cmd_ready;
    wire done;
    logic [31:0] rows = 64;
    wire act_read, weight_read, scale_a_read, scale_b_read;
    logic act_valid = 0, weight_valid = 0;
    logic scale_a_valid = 0, scale_b_valid = 0;
    wire c_read, c_write;
    wire [2:0] c_read_reg, c_write_reg;
    wire [5:0] c_read_addr, c_write_addr;
    wire c_read_block, c_write_block;
    integer completions = 0;
    integer command_delay;
    integer row_case;
    integer row_counts [0:7];

    pe_ctrl dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_m_i(rows), .cfg_n_i(32'd1), .cfg_k_i(32'd32),
        .rs1_i(3'd0), .rs2_i(3'd1), .rd_i(3'd4),
        .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready),
        .cmd_rob_age_i(7'd0), .done_valid_o(done), .done_ready_i(1'b1),
        .rs1_data_i(256'd0), .rs1_data_valid_i(act_valid),
        .rs1_read_valid_o(act_read),
        .rs2_data_i(256'd0), .rs2_data_valid_i(weight_valid),
        .rs2_read_valid_o(weight_read),
        .rs1_scale_data_i({32{8'd127}}), .rs1_scale_data_valid_i(scale_a_valid),
        .rs1_scale_read_valid_o(scale_a_read),
        .rs2_scale_data_i({32{8'd127}}), .rs2_scale_data_valid_i(scale_b_valid),
        .rs2_scale_read_valid_o(scale_b_read),
        .rd_data_i(1024'd0), .rd_data_valid_i(1'b1), .c_reg_zero_n_i(4'hf),
        .rd_read_valid_o(c_read), .rd_read_o(c_read_reg),
        .rd_read_addr_o(c_read_addr), .rd_read_nblock_o(c_read_block),
        .rd_write_valid_o(c_write), .rd_write_o(c_write_reg),
        .rd_write_addr_o(c_write_addr), .rd_write_nblock_o(c_write_block)
    );

    always @(posedge clk) begin
        act_valid <= rst_n && act_read;
        weight_valid <= rst_n && weight_read;
        scale_a_valid <= rst_n && scale_a_read;
        scale_b_valid <= rst_n && scale_b_read;
        if (!rst_n) completions <= 0;
        else begin
            if (done) completions <= completions + 1;
            // A single-port C bank cannot accept a read and write together,
            // even when their row addresses differ.
            if (c_read && c_write && c_read_reg == c_write_reg &&
                c_read_addr[0] == c_write_addr[0])
                $fatal(1, "C bank collision: M=%0d delay=%0d read=%0d/%0d write=%0d/%0d",
                    rows, command_delay, c_read_block, c_read_addr,
                    c_write_block, c_write_addr);
        end
    end

    task automatic send_command;
        begin
            cmd_valid = 1;
            do @(posedge clk); while (!cmd_ready);
            @(negedge clk);
            cmd_valid = 0;
        end
    endtask

    initial begin
        row_counts[0] = 64;
        row_counts[1] = 63;
        row_counts[2] = 33;
        row_counts[3] = 32;
        row_counts[4] = 31;
        row_counts[5] = 3;
        row_counts[6] = 2;
        row_counts[7] = 1;
        for (row_case = 0; row_case < 8; row_case = row_case + 1) begin
            rows = row_counts[row_case];
            for (command_delay = 0; command_delay < 24; command_delay = command_delay + 1) begin
                rst_n = 0;
                repeat (3) @(negedge clk);
                rst_n = 1;
                send_command;
                wait (act_read);
                @(negedge clk);
                repeat ((rows > 16 ? rows - 16 : 0) + command_delay) @(negedge clk);
                send_command;
                wait (completions == 2);
                repeat (2) @(negedge clk);
            end
            $display("PASS: M=%0d, 24 command gaps", rows);
            $fflush();
        end
        $display("PASS: 192 same-C MATMUL boundary cases, M=1..64 and variable command gaps");
        $finish;
    end

    initial #1000000 $fatal(1, "timeout");
endmodule
