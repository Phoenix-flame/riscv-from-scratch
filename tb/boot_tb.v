`timescale 1ns/1ps
`default_nettype none
// =====================================================================
// boot_tb.v  -  the boot platform with a serial cable attached
// ---------------------------------------------------------------------
// soc_boot holds nothing but its boot ROM. This bench is the other end
// of the UART: it decodes everything the machine transmits (echoed, and
// written to +LOG=), and it sends the boot images. +STREAM= is a file of
// chunks, each a 4-byte little-endian length and that many bytes; the
// bench waits for the ROM's "boot> " prompt before sending each chunk,
// so chunk n goes to the n-th time the ROM asks (tools/rvboot builds it).
//
// Runs until the test device powers the machine off (or fails it), then
// writes the DTB the ROM left at the top of RAM to +DTB= so that dtc can
// check it, and prints a one-line summary for tools/rvboot to parse.
// Runs under Icarus and under Verilator (--binary --timing).
// =====================================================================
module boot_tb;
    parameter RAM_WORDS = 65536;          // must match platform/soc_boot
    parameter DIVISOR   = 1;              // platform.h UART_DIVISOR
    localparam CPB = 16 * DIVISOR;        // clocks per bit

    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    reg  rx = 1'b1;
    wire tx, halted, warm_reset;
    wire [15:0] exit_code;

    soc_boot #(.RAM_WORDS(RAM_WORDS)) dut (
        .clk(clk), .rst(rst), .uart_rx_pin(rx), .uart_tx_pin(tx),
        .halted(halted), .exit_code(exit_code), .warm_reset(warm_reset));

    reg [8*256-1:0] romf, streamf, logf, dtbf;
    integer cyc = 0, maxcyc = 40000000, resets = 0, logfd = 0;
    always @(posedge clk) if (!rst) cyc <= cyc + 1;
    reg wr_q = 1'b0;
    always @(posedge clk) begin
        wr_q <= warm_reset;
        if (warm_reset && !wr_q) resets <= resets + 1;
    end

    // how close the ROM comes to losing bytes: the RX FIFO's high-water mark
    integer rx_peak = 0;
    always @(posedge clk) if (!rst && dut.u_uart.rx_n > rx_peak) rx_peak <= dut.u_uart.rx_n;

    // ---- receive: decode the TX line (8N1) ----
    reg [47:0] last6 = 48'd0;             // the last six characters seen
    integer prompts = 0, nrx = 0;
    reg [7:0] ch;
    integer i;
    initial begin
        forever begin
            @(negedge tx);
            repeat (CPB / 2) @(posedge clk);
            if (tx == 1'b0) begin
                for (i = 0; i < 8; i = i + 1) begin
                    repeat (CPB) @(posedge clk);
                    ch[i] = tx;
                end
                repeat (CPB) @(posedge clk);           // stop bit
                if (ch != 8'h0d) $write("%c", ch);
                if (logfd != 0) $fwrite(logfd, "%c", ch);
                nrx = nrx + 1;
                last6 = {last6[39:0], ch};
                if (last6 == "boot> ") prompts = prompts + 1;
            end
        end
    end

    // ---- send: one chunk per prompt ----
    task send_byte; input [7:0] b; integer k; begin
        rx = 1'b0; repeat (CPB) @(posedge clk);
        for (k = 0; k < 8; k = k + 1) begin rx = b[k]; repeat (CPB) @(posedge clk); end
        rx = 1'b1; repeat (CPB) @(posedge clk);
    end endtask

    integer sfd, len, n, c, chunk = 0, sent = 0;
    initial begin
        if (!$value$plusargs("ROM=%s", romf)) begin $display("boot_tb: need +ROM="); $finish; end
        $readmemh(romf, dut.rom);
        if ($value$plusargs("MAXCYC=%d", maxcyc)) ;
        if ($value$plusargs("LOG=%s", logf)) logfd = $fopen(logf, "w");
        sfd = 0;
        if ($value$plusargs("STREAM=%s", streamf)) sfd = $fopen(streamf, "rb");
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        if (sfd != 0) begin
            c = $fgetc(sfd);
            while (c != -1) begin
                len = c;
                len = len | ($fgetc(sfd) << 8);
                len = len | ($fgetc(sfd) << 16);
                len = len | ($fgetc(sfd) << 24);
                while (prompts <= chunk) @(posedge clk);
                repeat (4 * CPB) @(posedge clk);
                for (n = 0; n < len; n = n + 1) send_byte($fgetc(sfd));
                sent = sent + len;
                chunk = chunk + 1;
                c = $fgetc(sfd);
            end
            $fclose(sfd);
        end
    end

    // ---- finish ----
    integer dfd, w;
    reg [31:0] word;
    initial begin
        while (halted !== 1'b1 && cyc < maxcyc) @(posedge clk);
        repeat (4 * CPB) @(posedge clk);
        if (logfd != 0) $fclose(logfd);
        if ($value$plusargs("DTB=%s", dtbf)) begin
            dfd = $fopen(dtbf, "wb");
            for (w = RAM_WORDS - 2048; w < RAM_WORDS; w = w + 1) begin
                word = dut.ram[w];
                $fwrite(dfd, "%c%c%c%c", word[7:0], word[15:8], word[23:16], word[31:24]);
            end
            $fclose(dfd);
        end
        $display("");
        $display("BOOT-TB: %0s exit=%0d cycles=%0d resets=%0d chunks=%0d sent=%0d received=%0d rxfifo_peak=%0d",
                 halted ? "halted" : "TIMEOUT", exit_code, cyc, resets, chunk, sent, nrx, rx_peak);
        $finish;
    end
endmodule
`default_nettype wire
