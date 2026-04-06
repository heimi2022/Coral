`timescale 1ns/1ps

module MatrixCore_tb;

    logic         clk;
    logic         rst_n;

    logic         cmd_valid_i;
    logic         cmd_ready_o;
    logic [1:0]   cmd_ms1_i;
    logic [1:0]   cmd_ms2_i;
    logic [1:0]   cmd_md_i;

    logic [31:0]  cfg_m_i;
    logic [31:0]  cfg_k_i;
    logic [31:0]  cfg_n_i;
    logic         cfg_xmsaten_i;

    logic         busy_o;
    logic         done_valid_o;
    logic         done_illegal_o;

    logic         xmsat_set_valid_o;
    logic         xmsat_set_bits_o;

    logic         tile_dbg_wr_en_i;
    logic [1:0]   tile_dbg_wr_reg_i;
    logic [1023:0] tile_dbg_wr_data_i;
    logic         acc_dbg_wr_en_i;
    logic [1:0]   acc_dbg_wr_reg_i;
    logic [511:0] acc_dbg_wr_data_i;
    logic         dbg_tile_rd_en_i;
    logic [1:0]   dbg_tile_rd_reg_i;
    logic [1023:0] dbg_tile_rd_data_o;
    logic         dbg_acc_rd_en_i;
    logic [1:0]   dbg_acc_rd_reg_i;
    logic [511:0] dbg_acc_rd_data_o;

    integer error_count;

    MatrixCore dut (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_valid_i(cmd_valid_i),
        .cmd_ready_o(cmd_ready_o),
        .cmd_ms1_i(cmd_ms1_i),
        .cmd_ms2_i(cmd_ms2_i),
        .cmd_md_i(cmd_md_i),
        .cfg_m_i(cfg_m_i),
        .cfg_k_i(cfg_k_i),
        .cfg_n_i(cfg_n_i),
        .cfg_xmsaten_i(cfg_xmsaten_i),
        .busy_o(busy_o),
        .done_valid_o(done_valid_o),
        .done_illegal_o(done_illegal_o),
        .xmsat_set_valid_o(xmsat_set_valid_o),
        .xmsat_set_bits_o(xmsat_set_bits_o),
        .tile_dbg_wr_en_i(tile_dbg_wr_en_i),
        .tile_dbg_wr_reg_i(tile_dbg_wr_reg_i),
        .tile_dbg_wr_data_i(tile_dbg_wr_data_i),
        .acc_dbg_wr_en_i(acc_dbg_wr_en_i),
        .acc_dbg_wr_reg_i(acc_dbg_wr_reg_i),
        .acc_dbg_wr_data_i(acc_dbg_wr_data_i),
        .dbg_tile_rd_en_i(dbg_tile_rd_en_i),
        .dbg_tile_rd_reg_i(dbg_tile_rd_reg_i),
        .dbg_tile_rd_data_o(dbg_tile_rd_data_o),
        .dbg_acc_rd_en_i(dbg_acc_rd_en_i),
        .dbg_acc_rd_reg_i(dbg_acc_rd_reg_i),
        .dbg_acc_rd_data_o(dbg_acc_rd_data_o)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        $dumpfile("MatrixCore_tb.vcd");
        $dumpvars(0, MatrixCore_tb);
    end

    task automatic init_inputs;
        begin
            rst_n = 1'b0;
            cmd_valid_i = 1'b0;
            cmd_ms1_i = '0;
            cmd_ms2_i = '0;
            cmd_md_i = '0;
            cfg_m_i = '0;
            cfg_k_i = '0;
            cfg_n_i = '0;
            cfg_xmsaten_i = 1'b0;
            tile_dbg_wr_en_i = 1'b0;
            tile_dbg_wr_reg_i = '0;
            tile_dbg_wr_data_i = '0;
            acc_dbg_wr_en_i = 1'b0;
            acc_dbg_wr_reg_i = '0;
            acc_dbg_wr_data_i = '0;
            dbg_tile_rd_en_i = 1'b0;
            dbg_tile_rd_reg_i = '0;
            dbg_acc_rd_en_i = 1'b0;
            dbg_acc_rd_reg_i = '0;
            error_count = 0;
        end
    endtask

    task automatic apply_reset;
        begin
            init_inputs();
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic set_tile_elem(
        inout logic [1023:0] tile,
        input integer row,
        input integer col,
        input signed [7:0] value
    );
        begin
            tile[row * 256 + col * 8 +: 8] = value[7:0];
        end
    endtask

    task automatic set_acc_elem(
        inout logic [511:0] acc,
        input integer row,
        input integer col,
        input signed [31:0] value
    );
        begin
            acc[row * 128 + col * 32 +: 32] = value[31:0];
        end
    endtask

    function automatic signed [31:0] get_acc_elem(
        input logic [511:0] acc,
        input integer row,
        input integer col
    );
        begin
            get_acc_elem = $signed(acc[row * 128 + col * 32 +: 32]);
        end
    endfunction

    task automatic dbg_write_tile(
        input logic [1:0] reg_idx,
        input logic [1023:0] data
    );
        begin
            @(negedge clk);
            tile_dbg_wr_reg_i = reg_idx;
            tile_dbg_wr_data_i = data;
            tile_dbg_wr_en_i = 1'b1;
            @(negedge clk);
            tile_dbg_wr_en_i = 1'b0;
            tile_dbg_wr_reg_i = '0;
            tile_dbg_wr_data_i = '0;
        end
    endtask

    task automatic dbg_write_acc(
        input logic [1:0] reg_idx,
        input logic [511:0] data
    );
        begin
            @(negedge clk);
            acc_dbg_wr_reg_i = reg_idx;
            acc_dbg_wr_data_i = data;
            acc_dbg_wr_en_i = 1'b1;
            @(negedge clk);
            acc_dbg_wr_en_i = 1'b0;
            acc_dbg_wr_reg_i = '0;
            acc_dbg_wr_data_i = '0;
        end
    endtask

    task automatic dbg_read_acc(
        input logic [1:0] reg_idx,
        output logic [511:0] data
    );
        begin
            dbg_acc_rd_reg_i = reg_idx;
            dbg_acc_rd_en_i = 1'b1;
            #1;
            data = dbg_acc_rd_data_o;
            dbg_acc_rd_en_i = 1'b0;
            dbg_acc_rd_reg_i = '0;
            #1;
        end
    endtask

    task automatic issue_cmd(
        input logic [1:0] ms1,
        input logic [1:0] ms2,
        input logic [1:0] md
    );
        begin
            while (cmd_ready_o !== 1'b1) @(negedge clk);
            cmd_ms1_i = ms1;
            cmd_ms2_i = ms2;
            cmd_md_i = md;
            cmd_valid_i = 1'b1;
            @(negedge clk);
            cmd_valid_i = 1'b0;
            cmd_ms1_i = '0;
            cmd_ms2_i = '0;
            cmd_md_i = '0;
        end
    endtask

    task automatic wait_done_and_check(
        input bit expected_illegal,
        input bit expected_sat
    );
        begin
            wait (done_valid_o === 1'b1);
            #1;

            if (done_illegal_o !== expected_illegal) begin
                $display("TB ERROR: done_illegal_o got=%0b exp=%0b", done_illegal_o, expected_illegal);
                error_count = error_count + 1;
            end

            if (xmsat_set_valid_o !== expected_sat) begin
                $display("TB ERROR: xmsat_set_valid_o got=%0b exp=%0b", xmsat_set_valid_o, expected_sat);
                error_count = error_count + 1;
            end

            if (xmsat_set_bits_o !== expected_sat) begin
                $display("TB ERROR: xmsat_set_bits_o got=%0b exp=%0b", xmsat_set_bits_o, expected_sat);
                error_count = error_count + 1;
            end

            @(negedge clk);
        end
    endtask

    task automatic check_acc_elem(
        input integer test_id,
        input logic [511:0] acc,
        input integer row,
        input integer col,
        input signed [31:0] expected
    );
        reg signed [31:0] got;
        begin
            got = get_acc_elem(acc, row, col);
            if (got !== expected) begin
                $display(
                    "TB ERROR: test=%0d row=%0d col=%0d got=%0d exp=%0d",
                    test_id, row, col, got, expected
                );
                error_count = error_count + 1;
            end
        end
    endtask

    task automatic test_basic_mmacc;
        logic [1023:0] tile_a;
        logic [1023:0] tile_b;
        logic [511:0] acc_init;
        logic [511:0] acc_got;
        begin
            $display("TB INFO: test_basic_mmacc");
            tile_a = '0;
            tile_b = '0;
            acc_init = '0;

            set_tile_elem(tile_a, 0, 0, 8'sd1);
            set_tile_elem(tile_a, 0, 1, 8'sd2);
            set_tile_elem(tile_a, 0, 2, 8'sd3);
            set_tile_elem(tile_a, 0, 3, 8'sd4);
            set_tile_elem(tile_a, 1, 0, -8'sd1);
            set_tile_elem(tile_a, 1, 1, 8'sd0);
            set_tile_elem(tile_a, 1, 2, 8'sd1);
            set_tile_elem(tile_a, 1, 3, 8'sd2);

            set_tile_elem(tile_b, 0, 0, 8'sd5);
            set_tile_elem(tile_b, 0, 1, 8'sd6);
            set_tile_elem(tile_b, 0, 2, 8'sd7);
            set_tile_elem(tile_b, 0, 3, 8'sd8);
            set_tile_elem(tile_b, 1, 0, -8'sd2);
            set_tile_elem(tile_b, 1, 1, 8'sd1);
            set_tile_elem(tile_b, 1, 2, 8'sd0);
            set_tile_elem(tile_b, 1, 3, 8'sd3);
            set_tile_elem(tile_b, 2, 0, 8'sd1);
            set_tile_elem(tile_b, 2, 1, 8'sd1);
            set_tile_elem(tile_b, 2, 2, 8'sd1);
            set_tile_elem(tile_b, 2, 3, 8'sd1);

            cfg_m_i = 32'd2;
            cfg_k_i = 32'd4;
            cfg_n_i = 32'd3;
            cfg_xmsaten_i = 1'b0;

            dbg_write_tile(2'd0, tile_a);
            dbg_write_tile(2'd1, tile_b);
            dbg_write_acc(2'd0, acc_init);

            issue_cmd(2'd0, 2'd1, 2'd0);
            wait_done_and_check(1'b0, 1'b0);
            dbg_read_acc(2'd0, acc_got);

            check_acc_elem(1, acc_got, 0, 0, 32'sd70);
            check_acc_elem(1, acc_got, 0, 1, 32'sd12);
            check_acc_elem(1, acc_got, 0, 2, 32'sd10);
            check_acc_elem(1, acc_got, 1, 0, 32'sd18);
            check_acc_elem(1, acc_got, 1, 1, 32'sd8);
            check_acc_elem(1, acc_got, 1, 2, 32'sd2);
            check_acc_elem(1, acc_got, 0, 3, 32'sd0);
            check_acc_elem(1, acc_got, 2, 0, 32'sd0);
            check_acc_elem(1, acc_got, 3, 3, 32'sd0);
        end
    endtask

    task automatic test_k_tail_and_accumulate;
        logic [1023:0] tile_a;
        logic [1023:0] tile_b;
        logic [511:0] acc_init;
        logic [511:0] acc_got;
        begin
            $display("TB INFO: test_k_tail_and_accumulate");
            tile_a = '0;
            tile_b = '0;
            acc_init = '0;

            set_tile_elem(tile_a, 0, 0, 8'sd10);
            set_tile_elem(tile_a, 0, 1, -8'sd3);
            set_tile_elem(tile_a, 0, 2, 8'sd99);
            set_tile_elem(tile_a, 0, 3, -8'sd100);

            set_tile_elem(tile_b, 0, 0, 8'sd4);
            set_tile_elem(tile_b, 0, 1, 8'sd5);
            set_tile_elem(tile_b, 0, 2, 8'sd7);
            set_tile_elem(tile_b, 0, 3, -8'sd8);

            set_acc_elem(acc_init, 0, 0, 32'sd7);
            set_acc_elem(acc_init, 0, 1, 32'sd9);
            set_acc_elem(acc_init, 1, 0, -32'sd4);

            cfg_m_i = 32'd1;
            cfg_k_i = 32'd2;
            cfg_n_i = 32'd1;
            cfg_xmsaten_i = 1'b0;

            dbg_write_tile(2'd2, tile_a);
            dbg_write_tile(2'd3, tile_b);
            dbg_write_acc(2'd1, acc_init);

            issue_cmd(2'd2, 2'd3, 2'd1);
            wait_done_and_check(1'b0, 1'b0);
            dbg_read_acc(2'd1, acc_got);

            check_acc_elem(2, acc_got, 0, 0, 32'sd32);
            check_acc_elem(2, acc_got, 0, 1, 32'sd0);
            check_acc_elem(2, acc_got, 1, 0, 32'sd0);
            check_acc_elem(2, acc_got, 3, 3, 32'sd0);
        end
    endtask

    task automatic test_positive_saturation;
        logic [1023:0] tile_a;
        logic [1023:0] tile_b;
        logic [511:0] acc_init;
        logic [511:0] acc_got;
        integer k;
        begin
            $display("TB INFO: test_positive_saturation");
            tile_a = '0;
            tile_b = '0;
            acc_init = '0;

            for (k = 0; k < 32; k = k + 1) begin
                set_tile_elem(tile_a, 0, k, 8'sd127);
                set_tile_elem(tile_b, 0, k, 8'sd127);
            end

            set_acc_elem(acc_init, 0, 0, 32'sh7fff_ffff);

            cfg_m_i = 32'd1;
            cfg_k_i = 32'd32;
            cfg_n_i = 32'd1;
            cfg_xmsaten_i = 1'b1;

            dbg_write_tile(2'd1, tile_a);
            dbg_write_tile(2'd2, tile_b);
            dbg_write_acc(2'd2, acc_init);

            issue_cmd(2'd1, 2'd2, 2'd2);
            wait_done_and_check(1'b0, 1'b1);
            dbg_read_acc(2'd2, acc_got);

            check_acc_elem(3, acc_got, 0, 0, 32'sh7fff_ffff);
            check_acc_elem(3, acc_got, 0, 1, 32'sd0);
            check_acc_elem(3, acc_got, 1, 0, 32'sd0);
        end
    endtask

    task automatic test_illegal_cfg;
        logic [1023:0] tile_a;
        logic [1023:0] tile_b;
        logic [511:0] acc_init;
        logic [511:0] acc_got;
        begin
            $display("TB INFO: test_illegal_cfg");
            tile_a = '0;
            tile_b = '0;
            acc_init = '0;

            set_tile_elem(tile_a, 0, 0, 8'sd3);
            set_tile_elem(tile_b, 0, 0, 8'sd4);
            set_acc_elem(acc_init, 0, 0, 32'sd1234);

            cfg_m_i = 32'd5;
            cfg_k_i = 32'd1;
            cfg_n_i = 32'd1;
            cfg_xmsaten_i = 1'b0;

            dbg_write_tile(2'd0, tile_a);
            dbg_write_tile(2'd1, tile_b);
            dbg_write_acc(2'd3, acc_init);

            issue_cmd(2'd0, 2'd1, 2'd3);
            wait_done_and_check(1'b1, 1'b0);
            dbg_read_acc(2'd3, acc_got);

            check_acc_elem(4, acc_got, 0, 0, 32'sd1234);
        end
    endtask

    initial begin
        apply_reset();

        test_basic_mmacc();
        test_k_tail_and_accumulate();
        test_positive_saturation();
        test_illegal_cfg();

        if (error_count == 0) begin
            $display("TB PASS: MatrixCore_tb");
        end else begin
            $display("TB FAIL: MatrixCore_tb errors=%0d", error_count);
            $fatal(1);
        end

        #20;
        $finish;
    end

endmodule
