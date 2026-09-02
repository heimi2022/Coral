// One-time SPI master for bringing Coral out of reset into a JTAG-wait state.
// It uses the in-SoC Spi2TLUL protocol and releases the SPI pins after boot.
module CoralSpiBootMaster #(
    parameter logic [31:0] BOOT_STUB_ADDR = 32'h0000_0000,
    parameter integer SPI_CLK_DIV = 8,
    parameter integer START_DELAY_CYCLES = 256,
    parameter integer SPI_RESET_SYNC_CYCLES = 3,
    parameter integer STATUS_POLL_INTERVAL_CYCLES = 64,
    // The simulation model needs time for the SPI-to-TL async queues and the
    // TL write response before starting status-register SPI transactions.
    parameter integer POST_WRITE_WAIT_CYCLES = 4096,
    parameter integer COMMAND_WAIT_CYCLES = 64
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic spi_miso_i,
    output logic spi_clk_o,
    output logic spi_csb_o,
    output logic spi_mosi_o,
    output logic boot_active_o,
    output logic boot_done_o,
    output logic boot_error_o,
    output logic [7:0] boot_status_o,
    output logic [3:0] boot_state_o,
    output logic [2:0] boot_operation_o
);

    localparam integer SPI_DIV_WIDTH = (SPI_CLK_DIV <= 1) ? 1 : $clog2(SPI_CLK_DIV);
    localparam integer START_WAIT_WIDTH =
        (START_DELAY_CYCLES <= 1) ? 1 : $clog2(START_DELAY_CYCLES);
    localparam integer POST_WAIT_WIDTH =
        ((POST_WRITE_WAIT_CYCLES <= 1) && (COMMAND_WAIT_CYCLES <= 1)) ? 1 :
        $clog2((POST_WRITE_WAIT_CYCLES > COMMAND_WAIT_CYCLES) ?
                POST_WRITE_WAIT_CYCLES : COMMAND_WAIT_CYCLES);
    localparam integer SPI_SYNC_COUNT_WIDTH =
        (SPI_RESET_SYNC_CYCLES <= 1) ? 1 : $clog2(SPI_RESET_SYNC_CYCLES + 1);
    localparam integer STATUS_POLL_WAIT_WIDTH =
        (STATUS_POLL_INTERVAL_CYCLES <= 1) ? 1 : $clog2(STATUS_POLL_INTERVAL_CYCLES);

    localparam logic [31:0] CORE_CTRL_ADDR = 32'h0003_0000;
    // Sleep until JTAG asserts haltreq. CoreAxi includes haltreq and
    // debug_mode in its clock-gate enable, so debug can wake a WFI core.
    localparam logic [127:0] DEBUG_WAIT_STUB_DATA = {
        64'h0000_0000_0000_0000,
        32'h0000006f, // jal x0, 0 fallback after WFI
        32'h10500073  // wfi
    };

    typedef enum logic [3:0] {
        BootStartDelay,
        BootPrimeSpiClock,
        BootBeginTransaction,
        BootShiftTransaction,
        BootPostWriteWait,
        BootPollBegin,
        BootPollShift,
        BootPollWait,
        BootDone,
        BootError
    } boot_state_e;

    boot_state_e state;
    logic [2:0] operation_idx;
    logic [SPI_DIV_WIDTH-1:0] spi_div_count;
    logic [START_WAIT_WIDTH-1:0] start_wait_count;
    logic [SPI_SYNC_COUNT_WIDTH-1:0] spi_sync_count;
    logic [STATUS_POLL_WAIT_WIDTH-1:0] status_poll_wait_count;
    logic [POST_WAIT_WIDTH-1:0] post_wait_count;
    logic [5:0] byte_idx;
    logic [2:0] bit_idx;
    logic [7:0] tx_byte;
    logic [7:0] begin_tx_byte;
    logic [7:0] next_tx_byte;
    logic [7:0] status_poll_miso_byte;

    function automatic [5:0] operation_last_byte;
        input [2:0] op_number;
        begin
            operation_last_byte = op_number[0] ? 6'd1 : 6'd33;
        end
    endfunction

    function automatic [31:0] operation_addr;
        input [2:0] op_number;
        begin
            operation_addr = (op_number == 3'd0) ? BOOT_STUB_ADDR : CORE_CTRL_ADDR;
        end
    endfunction

    function automatic [127:0] operation_data;
        input [2:0] op_number;
        begin
            case (op_number)
                3'd0: operation_data = DEBUG_WAIT_STUB_DATA;
                // Match the official loader: first release the clock gate
                // while reset remains asserted, then write zero below.
                3'd1: operation_data = 128'h1;
                default: operation_data = '0;
            endcase
        end
    endfunction

    function automatic [7:0] operation_byte;
        input [2:0] op_number;
        input [5:0] byte_number;
        reg [31:0] addr;
        reg [127:0] data;
        begin
            addr = operation_addr(op_number);
            data = operation_data(op_number);
            case (byte_number)
                    6'd0:  operation_byte = 8'h80;
                    6'd1:  operation_byte = addr[7:0];
                    6'd2:  operation_byte = 8'h81;
                    6'd3:  operation_byte = addr[15:8];
                    6'd4:  operation_byte = 8'h82;
                    6'd5:  operation_byte = addr[23:16];
                    6'd6:  operation_byte = 8'h83;
                    6'd7:  operation_byte = addr[31:24];
                    6'd8:  operation_byte = 8'h84;
                    6'd9:  operation_byte = 8'h00; // One 128-bit TL beat.
                    6'd10: operation_byte = 8'h85;
                    6'd11: operation_byte = 8'h00;
                    6'd12: operation_byte = 8'h8a;
                    6'd13: operation_byte = 8'h0f; // Sixteen data bytes.
                    6'd14: operation_byte = 8'h8b;
                    6'd15: operation_byte = 8'h00;
                    6'd32: operation_byte = 8'h86;
                    6'd33: operation_byte = 8'h02; // CMD_WRITE_START
                    default: begin
                        if ((byte_number >= 6'd16) && (byte_number <= 6'd31))
                            operation_byte = data >> ((byte_number - 6'd16) * 8);
                        else
                            operation_byte = 8'h00;
                    end
            endcase
        end
    endfunction

    always @* begin
        if (operation_idx[0]) begin
            begin_tx_byte = 8'h86; // TL_CMD_REG write command.
            next_tx_byte = 8'h00;  // CMD_NULL clears the write FSM.
        end else begin
            begin_tx_byte = operation_byte(operation_idx >> 1, 6'd0);
            next_tx_byte = operation_byte(operation_idx >> 1, byte_idx + 1'b1);
        end
    end

    assign boot_error_o = (state == BootError);
    assign boot_state_o = state;
    assign boot_operation_o = operation_idx;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state <= BootStartDelay;
            operation_idx <= '0;
            spi_div_count <= '0;
            start_wait_count <= '0;
            spi_sync_count <= '0;
            status_poll_wait_count <= '0;
            post_wait_count <= '0;
            byte_idx <= '0;
            bit_idx <= '0;
            tx_byte <= '0;
            status_poll_miso_byte <= '0;
            boot_status_o <= '0;
            spi_clk_o <= 1'b0;
            spi_csb_o <= 1'b1;
            spi_mosi_o <= 1'b0;
            boot_active_o <= 1'b1;
            boot_done_o <= 1'b0;
        end else begin
            case (state)
                BootStartDelay: begin
                    if (start_wait_count == START_DELAY_CYCLES - 1) begin
                        spi_sync_count <= '0;
                        state <= BootPrimeSpiClock;
                    end else begin
                        start_wait_count <= start_wait_count + 1'b1;
                    end
                end

                // Let Spi2TLUL synchronize its reset before the first frame.
                BootPrimeSpiClock: begin
                    if (spi_div_count == SPI_CLK_DIV - 1) begin
                        spi_div_count <= '0;
                        if (!spi_clk_o) begin
                            spi_clk_o <= 1'b1;
                            spi_sync_count <= spi_sync_count + 1'b1;
                        end else begin
                            spi_clk_o <= 1'b0;
                            if (spi_sync_count == SPI_RESET_SYNC_CYCLES)
                                state <= BootBeginTransaction;
                        end
                    end else begin
                        spi_div_count <= spi_div_count + 1'b1;
                    end
                end

                BootBeginTransaction: begin
                    byte_idx <= '0;
                    bit_idx <= '0;
                    tx_byte <= begin_tx_byte;
                    spi_mosi_o <= begin_tx_byte[7];
                    spi_csb_o <= 1'b0;
                    spi_clk_o <= 1'b0;
                    spi_div_count <= '0;
                    state <= BootShiftTransaction;
                end

                BootShiftTransaction: begin
                    if (spi_div_count == SPI_CLK_DIV - 1) begin
                        spi_div_count <= '0;
                        if (!spi_clk_o) begin
                            // Spi2TLUL samples MOSI on this rising edge.
                            spi_clk_o <= 1'b1;
                        end else begin
                            spi_clk_o <= 1'b0;
                            if (bit_idx == 3'd7) begin
                                bit_idx <= '0;
                                if (byte_idx == operation_last_byte(operation_idx)) begin
                                    spi_csb_o <= 1'b1;
                                    spi_mosi_o <= 1'b0;
                                    post_wait_count <= '0;
                                    if (operation_idx == 3'd4) begin
                                        state <= BootDone;
                                        boot_active_o <= 1'b0;
                                        boot_done_o <= 1'b1;
                                    end else begin
                                        state <= BootPostWriteWait;
                                    end
                                end else begin
                                    byte_idx <= byte_idx + 1'b1;
                                    tx_byte <= next_tx_byte;
                                    spi_mosi_o <= next_tx_byte[7];
                                end
                            end else begin
                                bit_idx <= bit_idx + 1'b1;
                                spi_mosi_o <= tx_byte[6 - bit_idx];
                            end
                        end
                    end else begin
                        spi_div_count <= spi_div_count + 1'b1;
                    end
                end

                BootPostWriteWait: begin
                    // CMD_NULL only returns Spi2TLUL to Idle. It needs a short
                    // async-queue settling delay, not a full TL-write delay.
                    if (post_wait_count ==
                        ((operation_idx[0] ? COMMAND_WAIT_CYCLES : POST_WRITE_WAIT_CYCLES) - 1)) begin
                        if (operation_idx[0]) begin
                            operation_idx <= operation_idx + 1'b1;
                            state <= BootBeginTransaction;
                        end else begin
                            state <= BootPollBegin;
                        end
                    end else begin
                        post_wait_count <= post_wait_count + 1'b1;
                    end
                end

                // A read command returns the status prepared by the prior
                // poll. Repeating it handles the SPI-to-TL async latency.
                BootPollBegin: begin
                    bit_idx <= '0;
                    tx_byte <= 8'h09; // TL_WRITE_STATUS_REG read command.
                    status_poll_miso_byte <= '0;
                    spi_mosi_o <= 1'b0;
                    spi_csb_o <= 1'b0;
                    spi_clk_o <= 1'b0;
                    spi_div_count <= '0;
                    state <= BootPollShift;
                end

                BootPollShift: begin
                    if (spi_div_count == SPI_CLK_DIV - 1) begin
                        spi_div_count <= '0;
                        if (!spi_clk_o) begin
                            spi_clk_o <= 1'b1;
                        end else begin
                            spi_clk_o <= 1'b0;
                            // Spi2TLUL changes its MISO shifter on SCK rising
                            // edges. Sample on the falling edge, matching the
                            // existing spi_dpi_master timing.
                            status_poll_miso_byte <= {status_poll_miso_byte[6:0], spi_miso_i};
                            if (bit_idx == 3'd7) begin
                                spi_csb_o <= 1'b1;
                                spi_mosi_o <= 1'b0;
                                status_poll_wait_count <= '0;
                                state <= BootPollWait;
                            end else begin
                                bit_idx <= bit_idx + 1'b1;
                                spi_mosi_o <= tx_byte[6 - bit_idx];
                            end
                        end
                    end else begin
                        spi_div_count <= spi_div_count + 1'b1;
                    end
                end

                BootPollWait: begin
                    if (status_poll_wait_count == STATUS_POLL_INTERVAL_CYCLES - 1) begin
                        boot_status_o <= status_poll_miso_byte;
                        if (status_poll_miso_byte == 8'h02) begin
                            operation_idx <= operation_idx + 1'b1;
                            state <= BootBeginTransaction;
                        end else if (status_poll_miso_byte == 8'hff) begin
                            state <= BootError;
                            boot_active_o <= 1'b0;
                        end else begin
                            state <= BootPollBegin;
                        end
                    end else begin
                        status_poll_wait_count <= status_poll_wait_count + 1'b1;
                    end
                end

                default: begin
                    spi_clk_o <= 1'b0;
                    spi_csb_o <= 1'b1;
                    spi_mosi_o <= 1'b0;
                end
            endcase
        end
    end

endmodule
