// =====================================================================
// s6_boot_tb.v  -  the serial bootloader, end to end, in simulation
// ---------------------------------------------------------------------
// Boots sw/boot.hex, speaks the S6LD protocol at it over the rx pin, and
// checks that the uploaded program actually runs. This is the whole
// "change the firmware without re-synthesising" path -- including the bit
// that makes it possible at all, a store on the data port becoming an
// instruction on the fetch port of the same block RAM.
//
// The uploaded payload is five instructions, hand-assembled so the test
// does not depend on a second compile:
//
//   lui  t0, 0x20000        20000  2b7      t0 = SYSCON
//   lui  t1, 0x6            00006  337
//   addi t1, t1, 13         00d30 313      t1 = 0x600D
//   sw   t1, 0(t0)          00628 023      report and halt
//   j    .                  00000 06f
//
// A store to SYSCON halts the core and latches the value, so "did the
// uploaded code run?" reduces to "is tohost 0x600D?".
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module s6_boot_tb;
    localparam integer CLK_HZ = 1843200;
    localparam integer BAUD   = 115200;
    localparam integer BITC   = CLK_HZ / BAUD;
    localparam integer ENTRY  = 32'h0000_0800;

    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    wire uart_tx;
    reg  uart_rx = 1'b1;
    wire halted;
    wire [31:0] dbg_pc;

    s6_soc #(
        .CLK_HZ(CLK_HZ), .BAUD(BAUD),
        .MEM_WORDS(4096), .MEM_INIT("sw/boot.hex"),
        .GPIO_W(8), .ENABLE_SRAM(0)
    ) dut (
        .clk(clk), .rst(rst),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .uart_cts_n(1'b0), .uart_rts_n(),
        .gpio_out(), .gpio_in(8'h00),
        .sram_a(), .sram_dout(), .sram_din(8'h00),
        .sram_doe(), .sram_ce_n(), .sram_oe_n(), .sram_we_n(),
        .halted(halted), .dbg_pc(dbg_pc), .dbg_instr(), .dbg_retire()
    );

    // ---- serial monitor --------------------------------------------------
    reg [8*8-1:0] win = 0;
    reg           saw_banner = 1'b0;
    reg           got_r = 1'b0, got_k = 1'b0, got_bad = 1'b0;

    task tb_getc;
        output [7:0] b;
        integer i;
        begin
            @(negedge uart_tx);
            repeat (BITC + BITC/2) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = uart_tx;
                repeat (BITC) @(posedge clk);
            end
        end
    endtask

    // +UDBG=1 shows every byte the UART actually hands the bootloader,
    // which is the only way to tell a protocol bug from a framing bug.
    integer udbg;
    initial udbg = $test$plusargs("UDBG");
    always @(posedge clk) if (!rst && udbg && dut.u_uart.rxf_push)
        $display("[udbg %0t] rx %02h", $time, dut.u_uart.rx_byte);

    reg [7:0] ch;
    initial forever begin
        tb_getc(ch);
        $write("%c", ch);
        win = {win[8*7-1:0], ch};
        // Match the END of the banner, not the start. "s6boot" appears in
        // its first six characters, and a host that starts transmitting
        // there would be pushing bytes into a 16-deep RX FIFO while the
        // bootloader is still blocked inside uart_puts -- the tail of the
        // image would be dropped on the floor.
        // Match the printable tail of the banner. Not the leading
        // "s6boot": a host that starts transmitting there is pushing
        // bytes into a 16-deep RX FIFO while the bootloader is still
        // blocked inside uart_puts, and the tail of the image is dropped.
        // (Matching the trailing CR LF too would need "\r", which is not
        // a portable Verilog string escape.)
        if (win[8*6-1:0] == "(S6LD)") saw_banner <= 1'b1;
        if (saw_banner) begin
            if (ch == "R") got_r   <= 1'b1;
            if (ch == "K") got_k   <= 1'b1;
            if (ch == "E" || ch == "B") got_bad <= 1'b1;
        end
    end

    // ---- transmitter ------------------------------------------------------
    integer csum = 0;

    task tb_putc;
        input [7:0] b;
        integer i;
        begin
            uart_rx = 1'b0; repeat (BITC) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = b[i]; repeat (BITC) @(posedge clk);
            end
            uart_rx = 1'b1; repeat (BITC) @(posedge clk);
        end
    endtask

    task tb_put32;                       // little endian
        input [31:0] w;
        begin
            tb_putc(w[7:0]); tb_putc(w[15:8]);
            tb_putc(w[23:16]); tb_putc(w[31:24]);
        end
    endtask

    task tb_put_payload32;               // ... and add it to the checksum
        input [31:0] w;
        begin
            csum = csum + w[7:0]   + w[15:8] + w[23:16] + w[31:24];
            tb_put32(w);
        end
    endtask

    // =====================================================================
    integer errors = 0;

    initial begin
        repeat (8) @(posedge clk);
        #1 rst = 1'b0;

        wait (saw_banner);
        repeat (BITC * 30) @(posedge clk);   // let the trailing CR LF drain

        // magic
        tb_putc("S"); tb_putc("6"); tb_putc("L"); tb_putc("D");
        // header: 20 bytes, load at 0x800
        tb_put32(32'd20);
        tb_put32(ENTRY);
        // payload
        tb_put_payload32(32'h200002B7);          // lui  t0, 0x20000
        tb_put_payload32(32'h00006337);          // lui  t1, 0x6
        tb_put_payload32(32'h00D30313);          // addi t1, t1, 13
        tb_put_payload32(32'h0062A023);          // sw   t1, 0(t0)
        tb_put_payload32(32'h0000006F);          // j .
        // checksum
        tb_put32(csum[31:0]);

        wait (halted || got_bad);
        repeat (200) @(posedge clk);

        $display("\n--------------------------------------------------");
        if (!got_r) begin
            errors = errors + 1;
            $display("FAIL: the bootloader never acknowledged the magic ('R')");
        end
        if (got_bad) begin
            errors = errors + 1;
            $display("FAIL: the bootloader rejected the image ('E' or 'B')");
        end
        if (!got_k) begin
            errors = errors + 1;
            $display("FAIL: no 'K' -- the checksum did not match");
        end
        if (dut.tohost_r !== 32'h0000_600D) begin
            errors = errors + 1;
            $display("FAIL: uploaded code did not run (tohost=%08h, want 0000600d)",
                     dut.tohost_r);
        end

        if (errors == 0) $display("s6_boot_tb: PASS (uploaded 20 bytes and ran them)");
        else             $display("s6_boot_tb: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #100_000_000;
        $display("\ns6_boot_tb: TIMEOUT at pc=%08h", dbg_pc);
        $finish;
    end
endmodule

`default_nettype wire
