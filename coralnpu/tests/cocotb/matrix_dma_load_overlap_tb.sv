`timescale 1ns/1ps

module matrix_dma_load_overlap_tb;
    parameter integer READ_DEPTH = 16;
    localparam integer COMMANDS = 8;
    localparam integer MAX_BURSTS = 512;
    reg clk = 0;
    always #1 clk = !clk;
    reg rst_n = 0;
    reg mem_valid_i = 0;
    wire mem_ready_o, busy_o, done_valid_o, done_fault_o;
    reg [31:0] mem_pc_i = 0, mem_base_i = 0, mem_stride_i = 0;
    reg [2:0] mem_reg_i = 0;
    reg mem_ab_scale_sel_i = 0;
    reg [1:0] mem_elem_bytes_i = 0;
    reg [7:0] mem_rows_i = 0, mem_cols_i = 0;
    wire [31:0] done_pc_o, done_fault_addr_o;
    wire ab_wr_en_o, ab_wr_dst_sel_o, c_wr_en_o, c_wr_half_o, c_wr_nblock_o;
    wire [1:0] ab_wr_reg_o;
    wire [5:0] ab_wr_row_o;
    wire [511:0] ab_wr_data_o;
    wire m_axi_arvalid_o, m_axi_rready_o;
    reg m_axi_arready_i = 0, m_axi_rvalid_i = 0;
    wire [0:0] m_axi_arid_o;
    wire [31:0] m_axi_araddr_o;
    wire [7:0] m_axi_arlen_o;
    wire [2:0] m_axi_arsize_o;
    wire [1:0] m_axi_arburst_o;
    reg [0:0] m_axi_rid_i = 0;
    reg [511:0] m_axi_rdata_i = 0;
    reg [1:0] m_axi_rresp_i = 0;
    reg m_axi_rlast_i = 0;

    MatrixDmaLoad #(.READ_OUTSTANDING_DEPTH(READ_DEPTH)) dut (.*);

    integer bases [0:COMMANDS-1];
    integer strides [0:COMMANDS-1];
    integer rows [0:COMMANDS-1];
    integer cols [0:COMMANDS-1];
    integer elems [0:COMMANDS-1];
    integer regs [0:COMMANDS-1];
    integer scales [0:COMMANDS-1];
    integer wr_count [0:COMMANDS-1];
    integer first_ar [0:COMMANDS-1];
    integer done_cycle [0:COMMANDS-1];
    integer cmd_burst_count [0:COMMANDS-1];
    integer ar_address [0:MAX_BURSTS-1];
    integer ar_beats [0:MAX_BURSTS-1];
    integer ar_owner [0:MAX_BURSTS-1];
    integer ar_local [0:MAX_BURSTS-1];
    integer burst_count;
    integer return_delay = 60;
    reg fault_drained [0:COMMANDS-1];
    reg response_done [0:COMMANDS-1];

    function automatic [7:0] memory_byte(input integer address);
        memory_byte = (address * 13) ^ (address >> 6) ^ (address >> 13);
    endfunction

    task automatic add_burst(input integer owner, address, bytes);
        begin
            ar_address[burst_count] = (address / 64) * 64;
            ar_beats[burst_count] = ((address % 64) + bytes + 63) / 64;
            ar_owner[burst_count] = owner;
            ar_local[burst_count] = cmd_burst_count[owner];
            cmd_burst_count[owner] = cmd_burst_count[owner] + 1;
            burst_count = burst_count + 1;
        end
    endtask

    task automatic prepare(input integer strided);
        integer c, row, address, remaining, bytes, row_bytes;
        begin
            bases[0]='h1000; strides[0]=(strided==1) ? 128 : 64;
            rows[0]=64; cols[0]=64; elems[0]=0; regs[0]=0; scales[0]=0;
            bases[1]='h4000; strides[1]=64;
            rows[1]=2; cols[1]=1; elems[1]=0; regs[1]=1; scales[1]=1;
            bases[2]='h5ff1; strides[2]=512;
            rows[2]=3; cols[2]=63; elems[2]=2; regs[2]=7; scales[2]=0;
            bases[3]='h8203; strides[3]=1;
            rows[3]=64; cols[3]=1; elems[3]=0; regs[3]=2; scales[3]=0;
            bases[4]='ha03b; strides[4]=128;
            rows[4]=7; cols[4]=37; elems[4]=0; regs[4]=1; scales[4]=0;
            bases[5]='hb023; strides[5]=256;
            rows[5]=2; cols[5]=64; elems[5]=2; regs[5]=4; scales[5]=0;
            bases[6]='hc001; strides[6]=256;
            rows[6]=2; cols[6]=64; elems[6]=0; regs[6]=3; scales[6]=1;
            bases[7]='hd03f; strides[7]=17;
            rows[7]=3; cols[7]=17; elems[7]=0; regs[7]=3; scales[7]=0;
            if (strided==2) begin
                bases[0]='h103f; strides[0]=1; rows[0]=1; cols[0]=1;
                strides[1]=1; rows[1]=1;
                bases[2]='h5ffd; strides[2]=4; rows[2]=1; cols[2]=1;
            end
            burst_count = 0;
            for (c=0; c<COMMANDS; c=c+1) begin
                wr_count[c]=0; first_ar[c]=-1; done_cycle[c]=-1;
                cmd_burst_count[c]=0; fault_drained[c]=0; response_done[c]=0;
                row_bytes = cols[c] << elems[c];
                if (strides[c] == row_bytes &&
                    (bases[c] % 4096) + rows[c]*row_bytes <= 4096) begin
                    add_burst(c, bases[c], rows[c]*row_bytes);
                end else begin
                    for (row=0; row<rows[c]; row=row+1) begin
                        address=bases[c]+row*strides[c]; remaining=row_bytes;
                        while (remaining>0) begin
                            bytes=remaining;
                            if (bytes>4096-address%4096) bytes=4096-address%4096;
                            add_burst(c, address, bytes);
                            remaining=remaining-bytes; address=address+bytes;
                        end
                    end
                end
            end
        end
    endtask

    task automatic check_write(input integer owner);
        integer row_bytes, segments, row, offset, lane, address;
        reg [511:0] expected;
        begin
            if (owner>=COMMANDS) $fatal(1, "Unexpected extra register write");
            if (fault_drained[owner]) $fatal(1, "Write after fault, LOAD %0d", owner);
            row_bytes=cols[owner] << elems[owner]; segments=(row_bytes+63)/64;
            row=wr_count[owner]/segments; offset=(wr_count[owner]%segments)*64;
            if (row>=rows[owner]) $fatal(1, "Extra write for LOAD %0d", owner);
            expected=0;
            for (lane=0; lane<64; lane=lane+1) begin
                address=bases[owner]+row*strides[owner]+offset+lane;
                if (offset+lane<row_bytes) expected[lane*8 +: 8]=memory_byte(address);
            end
            if (ab_wr_data_o !== expected || ab_wr_reg_o !== (regs[owner] & 3) ||
                ab_wr_row_o !== row || ab_wr_dst_sel_o !== scales[owner] ||
                c_wr_en_o !== (regs[owner]>=4) || ab_wr_en_o !== (regs[owner]<4))
                $fatal(1, "Wrong write LOAD=%0d row=%0d offset=%0d got=%h want=%h",
                       owner, row, offset, ab_wr_data_o, expected);
            if (regs[owner]>=4 &&
                (c_wr_half_o !== ((offset/64)%2) || c_wr_nblock_o !== (offset/128)))
                $fatal(1, "Wrong C bank LOAD %0d", owner);
            wr_count[owner]=wr_count[owner]+1;
        end
    endtask

    // Drive on falling edges; check the signals consumed at the rising edge.
    task automatic run_case(input integer strided, stalled, fault_cmd, fault_burst,
                           fault_beat, abort_cycle);
        integer cycle, sent, accepted, returned, beat, completed, lane, owner;
        integer peak, credits, cmd_peak, expected_fault, expected_writes, finish_cycle;
        integer block_cycles, ar_stall_cycles, last_ar_cycle;
        reg held_r, held_ar;
        reg [42:0] saved_ar;
        begin
            @(negedge clk);
            rst_n=0; mem_valid_i=0; m_axi_rvalid_i=0; m_axi_arready_i=0;
            repeat (4) @(negedge clk);
            prepare(strided);
            rst_n=1;
            sent=0; accepted=0; returned=0; completed=0; beat=0;
            peak=0; cmd_peak=0; held_r=0; held_ar=0; finish_cycle=-1;
            block_cycles=0; ar_stall_cycles=0; last_ar_cycle=-1;
            begin : simulation
                for (cycle=0; cycle<20000; cycle=cycle+1) begin
                    @(negedge clk);
                    mem_valid_i=(sent<COMMANDS);
                    if (sent<COMMANDS) begin
                        mem_pc_i='h100+sent*4; mem_base_i=bases[sent];
                        mem_stride_i=strides[sent]; mem_reg_i=regs[sent];
                        mem_ab_scale_sel_i=scales[sent]; mem_elem_bytes_i=elems[sent];
                        mem_rows_i=rows[sent]; mem_cols_i=cols[sent];
                    end
                    m_axi_arready_i=(!stalled || cycle%7>=3);
                    if (!held_r && returned<accepted && cycle>=return_delay &&
                        (!stalled || cycle%5!=0)) begin
                        held_r=1;
                        for (lane=0; lane<64; lane=lane+1)
                            m_axi_rdata_i[lane*8 +: 8]=
                                memory_byte(ar_address[returned]+beat*64+lane);
                        m_axi_rlast_i=(beat==ar_beats[returned]-1);
                        m_axi_rresp_i=(ar_owner[returned]==fault_cmd &&
                            ar_local[returned]==fault_burst && beat==fault_beat) ? 2 : 0;
                    end
                    m_axi_rvalid_i=held_r;
                    @(posedge clk);
                    if (held_ar && (!m_axi_arvalid_o ||
                        {m_axi_araddr_o,m_axi_arlen_o,m_axi_arid_o,
                         m_axi_arburst_o} !== saved_ar))
                        $fatal(1, "AR changed under backpressure");
                    held_ar=m_axi_arvalid_o && !m_axi_arready_i;
                    saved_ar={m_axi_araddr_o,m_axi_arlen_o,m_axi_arid_o,m_axi_arburst_o};
                    if (held_ar) ar_stall_cycles=ar_stall_cycles+1;
                    if (ab_wr_en_o || c_wr_en_o) check_write(completed);
                    if (mem_valid_i && mem_ready_o) sent=sent+1;
                    if (mem_valid_i && !mem_ready_o) block_cycles=block_cycles+1;
                    if (m_axi_arvalid_o && m_axi_arready_i) begin
                        if (accepted>=burst_count) $fatal(1, "Extra AR");
                        if (m_axi_araddr_o !== ar_address[accepted] ||
                            m_axi_arlen_o !== (ar_beats[accepted]-1) ||
                            m_axi_arsize_o !== 3'd6 || m_axi_arburst_o !== 2'd1 ||
                            m_axi_arid_o !== 1'b0)
                            $fatal(1, "Wrong AR %0d addr=%h len=%0d",
                                   accepted, m_axi_araddr_o, m_axi_arlen_o);
                        owner=ar_owner[accepted];
                        if (first_ar[owner]<0) first_ar[owner]=cycle;
                        accepted=accepted+1; last_ar_cycle=cycle;
                    end
                    if (m_axi_rvalid_i && m_axi_rready_o) begin
                        held_r=0;
                        if (m_axi_rlast_i) begin
                            owner=ar_owner[returned];
                            if (owner==fault_cmd && ar_local[returned]==fault_burst)
                                fault_drained[owner]=1;
                            if (ar_local[returned]==cmd_burst_count[owner]-1)
                                response_done[owner]=1;
                            returned=returned+1; beat=0;
                        end else beat=beat+1;
                    end
                    if (done_valid_o) begin
                        if (completed>=COMMANDS) $fatal(1, "Extra completion");
                        expected_fault=(completed==fault_cmd);
                        if (done_pc_o !== ('h100+completed*4) ||
                            done_fault_o !== expected_fault || !response_done[completed])
                            $fatal(1, "Wrong/early completion LOAD=%0d PC=%h fault=%b",
                                   completed, done_pc_o, done_fault_o);
                        if (expected_fault && !fault_drained[completed])
                            $fatal(1, "Fault completion without error");
                        expected_writes=rows[completed]*(((cols[completed]<<elems[completed])+63)/64);
                        if (!expected_fault && wr_count[completed]!=expected_writes)
                            $fatal(1, "Early completion LOAD=%0d writes=%0d/%0d",
                                   completed, wr_count[completed], expected_writes);
                        if (expected_fault && done_fault_addr_o !== 32'd0)
                            $fatal(1, "Fault address contract changed");
                        done_cycle[completed]=cycle; completed=completed+1;
                    end
                    credits=accepted-returned;
                    if (credits>READ_DEPTH) $fatal(1, "Read credits overflow %0d", credits);
                    if (credits>peak) peak=credits;
                    if (sent-completed>4) $fatal(1, "Command credits overflow");
                    if (sent-completed>cmd_peak) cmd_peak=sent-completed;
                    if (abort_cycle>=0 && cycle==abort_cycle) begin
                        if (!busy_o || accepted==returned)
                            $fatal(1, "Reset test did not interrupt outstanding reads");
                        $display("PASS reset with %0d outstanding bursts", accepted-returned);
                        disable simulation;
                    end
                    if (completed==COMMANDS && finish_cycle<0) finish_cycle=cycle;
                    if (finish_cycle>=0 && cycle-finish_cycle==12) begin
                        if (busy_o || sent!=COMMANDS || accepted!=burst_count || returned!=accepted)
                            $fatal(1, "Incomplete drain or busy stuck");
                        if (first_ar[1]>=done_cycle[0])
                            $fatal(1, "LOAD requests remain serialized: AR1=%0d done0=%0d",
                                   first_ar[1], done_cycle[0]);
                        if (cmd_peak!=4 || block_cycles==0)
                            $fatal(1, "Command capacity/backpressure was not exercised");
                        if (strided==1 && peak!=READ_DEPTH)
                            $fatal(1, "Read outstanding did not fill: %0d/%0d", peak, READ_DEPTH);
                        if (stalled && ar_stall_cycles==0) $fatal(1, "No AR stalls");
                        $display("PASS strided=%0d stalls=%0d fault=%0d/%0d/%0d bursts=%0d peak=%0d AR1=%0d done0=%0d cycles=%0d",
                                 strided, stalled, fault_cmd, fault_burst, fault_beat,
                                 accepted, peak, first_ar[1], done_cycle[0], cycle);
                        disable simulation;
                    end
                    if (cycle==19999)
                        $fatal(1, "Timeout sent=%0d AR=%0d R=%0d done=%0d lastAR=%0d",
                               sent, accepted, returned, completed, last_ar_cycle);
                end
            end
        end
    endtask

    initial begin
        run_case(0, 0, -1, 0, 0, -1);
        run_case(0, 1, -1, 0, 0, -1);
        run_case(1, 0, -1, 0, 0, -1);
        run_case(1, 1, -1, 0, 0, -1);
        // Error on a nonfinal beat, an early burst, and the final command/beat.
        run_case(0, 0, 0, 0, 7, -1);
        run_case(1, 1, 0, 0, 0, -1);
        run_case(1, 0, 0, 20, 0, -1);
        run_case(0, 1, 1, 0, 0, -1);
        run_case(0, 1, 2, 0, 0, -1);
        run_case(0, 1, 2, 1, 2, -1);
        run_case(0, 0, 3, 0, 1, -1);
        run_case(0, 1, 7, 0, 1, -1);
        run_case(0, 0, -1, 0, 0, 65);
        run_case(0, 0, -1, 0, 0, -1);
        return_delay=0;
        run_case(2, 0, -1, 0, 0, -1);
        run_case(2, 1, -1, 0, 0, -1);
        $display("DMA LOAD overlap regression PASS (READ_DEPTH=%0d)", READ_DEPTH);
        $finish;
    end
endmodule
