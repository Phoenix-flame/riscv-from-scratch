// =====================================================================
// s6_soc_tb.v  -  run the real firmware on the whole SoC
// ---------------------------------------------------------------------
// Boots sw/hello.hex on s6_soc with a behavioural IS61WV5128BLL attached,
// decodes the serial output off the tx pin (so what you see in the log is
// literally what a terminal on the board would show), types into the echo
// loop, and checks the exit code the firmware reports through SYSCON.
//
// The clock is deliberately set to 1.8432 MHz so that CLK_HZ / 115200 is
// exactly 16 -- the fewest clocks per bit the oversampler allows, which
// keeps a full banner plus a self-test inside a few million simulation
// cycles.
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module s6_soc_tb;
    localparam integer CLK_HZ = 1843200;
    localparam integer BAUD   = 115200;
    localparam integer BITC   = CLK_HZ / BAUD;      // 16 clocks per bit

    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    wire uart_tx;
    reg  uart_rx = 1'b1;
    wire [7:0] gpio_out;
    reg  [7:0] gpio_in = 8'h00;
    wire halted;
    wire [31:0] dbg_pc;

    // ---- external SRAM ----
    wire [18:0] sram_a;
    wire [7:0]  sram_dout;
    wire        sram_doe, sram_ce_n, sram_oe_n, sram_we_n;
    wire [7:0]  sram_data;
    assign sram_data = sram_doe ? sram_dout : 8'bz;
    wire [7:0]  sram_din = sram_data;

    s6_soc #(
        .CLK_HZ(CLK_HZ), .BAUD(BAUD),
        .MEM_WORDS(4096), .MEM_INIT("sw/hello.hex"),
        .GPIO_W(8), .ENABLE_SRAM(1),
        .SRAM_RD_CYC(2), .SRAM_WR_CYC(2)
    ) dut (
        .clk(clk), .rst(rst),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .uart_cts_n(1'b0), .uart_rts_n(),
        .gpio_out(gpio_out), .gpio_in(gpio_in),
        .sram_a(sram_a), .sram_dout(sram_dout), .sram_din(sram_din),
        .sram_doe(sram_doe), .sram_ce_n(sram_ce_n),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
        .halted(halted), .dbg_pc(dbg_pc), .dbg_instr(), .dbg_retire()
    );

    s6_sram_model u_sram (
        .a(sram_a), .d(sram_data),
        .ce_n(sram_ce_n), .oe_n(sram_oe_n), .we_n(sram_we_n)
    );

    // =====================================================================
    // Decode the serial line the way a terminal would
    // =====================================================================
    reg [8*8-1:0] win = 0;              // rolling window for marker matching
    reg           saw_prompt = 1'b0;
    reg           watch_echo = 1'b0;
    reg           echo_a = 1'b0, echo_b = 1'b0;
    reg           saw_bye = 1'b0;

    task tb_getc;
        output [7:0] b;
        integer i;
        begin
            @(negedge uart_tx);                        // start bit
            repeat (BITC + BITC/2) @(posedge clk);     // to the middle of bit 0
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = uart_tx;
                repeat (BITC) @(posedge clk);
            end
        end
    endtask

    // +UDBG=1 traces the UART at both ends: what the CPU pushes into the
    // TX FIFO, and what the pin decoder gets back out. Any difference is
    // a hardware bug; a byte the CPU never pushed is a firmware bug.
    integer udbg;
    initial udbg = $test$plusargs("UDBG");

    always @(posedge clk) if (!rst && udbg) begin
        if (dut.u_uart.txf_push)
            $display("[udbg %0t] push  %02h '%c'%s", $time,
                     dut.u_uart.wdata[7:0], dut.u_uart.wdata[7:0],
                     dut.u_uart.txf_full ? " *** DROPPED (fifo full)" : "");
        if (dut.u_uart.rxf_push)
            $display("[udbg %0t] rx    %02h '%c'", $time,
                     dut.u_uart.rx_byte, dut.u_uart.rx_byte);
    end

    reg [7:0] ch;
    initial forever begin
        tb_getc(ch);
        if (udbg) $display("[udbg %0t] pin   %02h '%c'", $time, ch, ch);
        $write("%c", ch);
        win = {win[8*7-1:0], ch};
        if (win[8*5-1:0] == "quits") saw_prompt <= 1'b1;
        if (win[8*3-1:0] == "bye")   saw_bye    <= 1'b1;
        if (watch_echo && ch == "A") echo_a <= 1'b1;
        if (watch_echo && ch == "B") echo_b <= 1'b1;
    end

    task tb_putc;
        input [7:0] b;
        integer i;
        begin
            uart_rx = 1'b0; repeat (BITC) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = b[i]; repeat (BITC) @(posedge clk);
            end
            uart_rx = 1'b1; repeat (BITC * 2) @(posedge clk);
        end
    endtask

    // =====================================================================
    integer errors = 0;

    initial begin
        repeat (8) @(posedge clk);
        #1 rst = 1'b0;

        wait (saw_prompt);
        watch_echo = 1'b1;
        repeat (BITC * 4) @(posedge clk);

        tb_putc("A");
        tb_putc("B");
        repeat (BITC * 40) @(posedge clk);
        tb_putc("q");

        wait (halted);
        repeat (100) @(posedge clk);

        $display("\n--------------------------------------------------");
        if (dut.tohost_r !== 32'd0) begin
            errors = errors + 1;
            $display("FAIL: firmware reported %0d self-test failure(s)",
                     dut.tohost_r);
        end
        if (!echo_a || !echo_b) begin
            errors = errors + 1;
            $display("FAIL: the echo loop did not send 'A'/'B' back (a=%b b=%b)",
                     echo_a, echo_b);
        end
        if (!saw_bye) begin
            errors = errors + 1;
            $display("FAIL: never saw the 'bye' that follows 'q'");
        end

        if (errors == 0) $display("s6_soc_tb: PASS");
        else             $display("s6_soc_tb: FAIL (%0d errors)", errors);
        $finish;
    end

    // The whole run is ~250k clocks, almost all of it the CPU waiting on the
    // UART: at 16 clocks per bit a character costs 160 clocks, and the
    // firmware prints a few hundred of them.
    initial begin
        #15_000_000;                                   // 15 ms of simulated time
        $display("\ns6_soc_tb: TIMEOUT at pc=%08h", dbg_pc);
        $finish;
    end
endmodule

`default_nettype wire
