`timescale 1ns/1ps

module dtcm_256kb_tb;
    logic clock = 1'b0;
    logic access_valid = 1'b0;
    logic write = 1'b0;
    logic [3:0] bank_enable = 4'hf;
    logic [11:0] addr = '0;
    logic [511:0] wdata = '0;
    logic [63:0] wmask = '0;
    wire [511:0] rdata;

    logic [511:0] reference_data [0:4095];
    logic [31:0] random_state = 32'hd7c0256b;
    integer reads = 0;
    integer writes = 0;
    integer disabled_accesses = 0;

    always #10 clock = ~clock;

    DTCM_256KB dut (
        .clock  (clock),
        .write  (write),
        .bank_enable (bank_enable & {4{access_valid}}),
        .addr   (addr),
        .wdata  (wdata),
        .wmask  (wmask),
        .rdata  (rdata)
    );

    function automatic logic [511:0] pattern(input integer row, input bit invert);
        for (integer word_idx = 0; word_idx < 16; word_idx++) begin
            pattern[word_idx * 32 +: 32] =
                (32'h35a9c781 ^ (32'h01010101 * word_idx) ^ (32'h00010001 * row)) ^
                {32{invert}};
        end
    endfunction

    function automatic logic [31:0] next_random();
        random_state = random_state ^ (random_state << 13);
        random_state = random_state ^ (random_state >> 17);
        random_state = random_state ^ (random_state << 5);
        return random_state;
    endfunction

    // Every call occupies one cycle, including back-to-back unit changes.
    task automatic access(
        input bit access_enable,
        input bit access_write,
        input logic [11:0] row,
        input logic [511:0] data,
        input logic [63:0] mask
    );
        @(negedge clock);
        access_valid = access_enable;
        write = access_write;
        addr = row;
        wdata = data;
        wmask = mask;
        @(posedge clock);
        #3;
        if (access_enable && access_write) begin
            for (integer byte_idx = 0; byte_idx < 64; byte_idx++) begin
                if (bank_enable[byte_idx / 16] && mask[byte_idx]) begin
                    reference_data[row][byte_idx * 8 +: 8] = data[byte_idx * 8 +: 8];
                end
            end
            writes++;
        end else if (access_enable) begin
            for (integer bank_idx = 0; bank_idx < 4; bank_idx++) begin
                if (bank_enable[bank_idx] &&
                    rdata[bank_idx * 128 +: 128] !==
                    reference_data[row][bank_idx * 128 +: 128]) begin
                    $display("FAIL row=%0d unit=%0d bank=%0d expected=%032h actual=%032h",
                             row, row[11:10], bank_idx,
                             reference_data[row][bank_idx * 128 +: 128],
                             rdata[bank_idx * 128 +: 128]);
                    $fatal(1, "DTCM read mismatch");
                end
            end
            reads++;
        end else begin
            disabled_accesses++;
        end
    endtask

    task automatic read_row(input logic [11:0] row);
        bank_enable = 4'hf;
        access(1'b1, 1'b0, row, '1, '1);
    endtask

    initial begin : run
        logic [63:0] mask;
        logic [511:0] data;
        logic [511:0] held_data;
        logic [11:0] row;
        logic [31:0] choice;

        repeat (3) @(negedge clock);

        // Unique contents expose row aliasing and swapped 16-byte lanes.
        for (integer i = 0; i < 4096; i++) begin
            access(1'b1, 1'b1, 12'(i), pattern(i, 1'b0), '1);
        end
        for (integer i = 0; i < 4096; i++) begin
            read_row(12'(i));
        end
        $display("PASS full-capacity address and lane mapping");

        // Alternate units on every cycle, then reverse direction at boundaries.
        for (integer local_row = 0; local_row < 1024; local_row++) begin
            for (integer unit_idx = 3; unit_idx >= 0; unit_idx--) begin
                read_row(12'(unit_idx * 1024 + local_row));
            end
        end
        for (integer i = 4095; i >= 0; i--) begin
            access(1'b1, 1'b1, 12'(i), pattern(i, 1'b1), '1);
            read_row(12'(i));
        end
        $display("PASS consecutive unit switches and inverted full-capacity data");

        // Walking byte enables cover every lane in the first/last row of each unit.
        for (integer unit_idx = 0; unit_idx < 4; unit_idx++) begin
            for (integer edge_idx = 0; edge_idx < 2; edge_idx++) begin
                row = 12'(unit_idx * 1024 + edge_idx * 1023);
                for (integer byte_idx = 0; byte_idx < 64; byte_idx++) begin
                    mask = 64'b1 << byte_idx;
                    data = ~reference_data[row];
                    access(1'b1, 1'b1, row, data, mask);
                    read_row(row);
                end
                access(1'b1, 1'b1, row, '0, '0);
                read_row(row);
                access(1'b1, 1'b1, row, '0, 64'haaaaaaaaaaaaaaaa);
                read_row(row);
                access(1'b1, 1'b1, row, '1, 64'h5555555555555555);
                read_row(row);
            end
        end
        $display("PASS byte masks, zero masks and untouched-byte preservation");

        for (integer unit_idx = 0; unit_idx < 4; unit_idx++) begin
            row = 12'(unit_idx * 1024 + 17);
            access(1'b0, 1'b1, row, ~reference_data[row], '1);
            read_row(row);

            // Changing the request address without another rising edge must
            // not redirect the response from the read that just completed.
            held_data = rdata;
            addr = row ^ 12'hc00;
            #1;
            if (rdata !== held_data) begin
                $fatal(1, "Read response depends on the next request address");
            end
            access(1'b0, 1'b0, row ^ 12'hc00, '0, '0);
            if (rdata !== held_data) begin
                $fatal(1, "Disabled read changes the previous read response");
            end
        end
        $display("PASS disabled accesses and registered read-unit selection");

        // Deterministic random traffic mixes reads, writes and disabled cycles.
        for (integer i = 0; i < 10000; i++) begin
            choice = next_random();
            row = 12'(next_random());
            mask[31:0] = next_random();
            mask[63:32] = next_random();
            for (integer word_idx = 0; word_idx < 16; word_idx++) begin
                data[word_idx * 32 +: 32] = next_random();
            end
            access(choice[2:0] != 0, choice[3], row, data, mask);
            // Read back writes immediately to detect corruption at its source.
            if ((choice[2:0] != 0) && choice[3]) begin
                read_row(row);
            end
        end
        for (integer i = 0; i < 4096; i++) begin
            read_row(12'(i));
        end
        $display("PASS randomized traffic and final full-capacity readback");

        // A partial read updates only the selected 16-byte macro output.
        row = 12'(2 * 1024 + 41);
        read_row(row);
        held_data = rdata;
        bank_enable = 4'b0100;
        access(1'b1, 1'b0, row + 1'b1, '0, '0);
        for (integer bank_idx = 0; bank_idx < 4; bank_idx++) begin
            if (bank_idx == 2) begin
                if (rdata[bank_idx * 128 +: 128] !==
                    reference_data[row + 1'b1][bank_idx * 128 +: 128]) begin
                    $fatal(1, "Selected bank did not return requested row");
                end
            end else if (rdata[bank_idx * 128 +: 128] !==
                         held_data[bank_idx * 128 +: 128]) begin
                $fatal(1, "Unselected bank output changed during partial read");
            end
        end

        // A partial write cannot modify data held in disabled macro banks.
        bank_enable = 4'b0010;
        access(1'b1, 1'b1, row, ~reference_data[row], '1);
        read_row(row);
        $display("PASS selective read/write bank enables");

        $display("PASS DTCM_256KB reads=%0d writes=%0d disabled=%0d",
                 reads, writes, disabled_accesses);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "DTCM test timeout");
    end
endmodule
