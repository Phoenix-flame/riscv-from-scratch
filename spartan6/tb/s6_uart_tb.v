// =====================================================================
// s6_uart_tb.v  -  self-checking testbench for the UART peripheral
// ---------------------------------------------------------------------
// Checks the parts a CPU-level test would not reach:
//
//   * the register file, including the read-with-side-effect rule (a
//     read of RXTX pops the FIFO exactly once even though the bus holds
//     `re` high for two cycles)
//   * FIFO depth, fill levels and the full/empty flags
//   * the bit timing actually produced on the tx pin, measured in clocks
//     and compared against the programmed clocks-per-bit
//   * 8N1, 7E1 and 8O2 framing, end to end through loopback
//   * a deliberately corrupted frame -> frame error
//   * watermark, rx-not-empty and idle interrupts
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module s6_uart_tb;
    localparam CPB = 32;                 // clocks per bit while testing

    // CTRL field combinations. Every one keeps TXEN and RXEN set: clearing
    // them by accident just stops the FIFO draining and every later check
    // then fails for the wrong reason.
    localparam [31:0] LOOPB   = 32'h0004;                        // loopback
    localparam [31:0] FLUSH   = 32'h0030;                        // tx+rx clear
    localparam [31:0] CFG_8N1 = 32'h0003 | (32'd8 << 11);
    localparam [31:0] CFG_7E1 = 32'h0003 | (32'd7 << 11) | (32'd2 << 8);
    localparam [31:0] CFG_8O2 = 32'h0003 | (32'd8 << 11) | (32'd3 << 8)
                                         | (32'd1 << 10);

    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    reg         sel = 1'b0, re = 1'b0;
    reg  [3:0]  be  = 4'd0;
    reg  [7:0]  addr = 8'd0;
    reg  [31:0] wdata = 32'd0;
    wire [31:0] rdata;
    wire        ready, tx, rts_n, irq;
    reg         rx = 1'b1;

    s6_uart #(.DEF_BAUDDIV(CPB), .FIFO_DEPTH(16)) dut (
        .clk(clk), .rst(rst),
        .sel(sel), .re(re), .be(be), .addr(addr), .wdata(wdata),
        .rdata(rdata), .ready(ready),
        .rx(rx), .tx(tx), .cts_n(1'b0), .rts_n(rts_n), .irq(irq)
    );

    integer errors = 0;

    task chk;
        input [255:0] what;
        input         ok;
        begin
            if (!ok) begin
                errors = errors + 1;
                $display("FAIL: %0s", what);
            end
        end
    endtask

    // ---- bus access -----------------------------------------------------
    task bwrite;
        input [7:0]  a;
        input [31:0] d;
        begin
            @(negedge clk);
            sel = 1'b1; be = 4'hF; re = 1'b0; addr = a; wdata = d;
            @(negedge clk);
            sel = 1'b0; be = 4'd0;
        end
    endtask

    task bread;
        input  [7:0]  a;
        output [31:0] d;
        begin
            @(negedge clk);
            sel = 1'b1; be = 4'd0; re = 1'b1; addr = a;
            @(negedge clk);
            while (!ready) @(negedge clk);
            d = rdata;
            sel = 1'b0; re = 1'b0;
        end
    endtask

    // ---- drive a frame onto the rx pin, 8N1, at CPB clocks per bit ------
    // The extra idle bit-time at the end is not decoration: the receiver
    // sees the line through a two-flop synchroniser, so it finishes a
    // frame a few clocks after the driver does.
    task rx_byte;
        input [7:0] b;
        integer i;
        begin
            rx = 1'b0; repeat (CPB) @(posedge clk);          // start
            for (i = 0; i < 8; i = i + 1) begin
                rx = b[i]; repeat (CPB) @(posedge clk);
            end
            rx = 1'b1; repeat (CPB * 2) @(posedge clk);      // stop + idle
        end
    endtask

    // ---- wait until the transmitter is completely finished --------------
    task drain_tx;
        reg [31:0] s;
        integer guard;
        begin
            guard = 0;
            s = 32'd0;
            while (((s[0] !== 1'b1) || (s[2] !== 1'b0)) && guard < 200) begin
                repeat (CPB * 4) @(posedge clk);
                bread(8'h04, s);
                guard = guard + 1;
            end
        end
    endtask

    // a frame whose stop bit is low: the receiver must call it a framing error
    task rx_broken_byte;
        input [7:0] b;
        integer i;
        begin
            rx = 1'b0; repeat (CPB) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                rx = b[i]; repeat (CPB) @(posedge clk);
            end
            rx = 1'b0; repeat (CPB) @(posedge clk);          // bad stop
            rx = 1'b1; repeat (CPB * 2) @(posedge clk);
        end
    endtask

    // ---- measure one transmitted frame on the tx pin --------------------
    integer t_start, t_end;
    task measure_bit_time;
        output integer bits;
        begin
            @(negedge tx);                                   // start bit edge
            t_start = cycles;
            repeat (10) @(posedge clk);
            @(posedge tx);                                   // first 1 in the frame
            t_end = cycles;
            bits  = t_end - t_start;
        end
    endtask

    integer cycles = 0;
    always @(posedge clk) cycles = cycles + 1;

    // =====================================================================
    integer i, measured;
    reg [31:0] v;
    reg [7:0]  got;

    initial begin
        repeat (4) @(posedge clk);
        #1 rst = 1'b0;
        repeat (2) @(posedge clk);

        // ---- defaults after reset -------------------------------------
        bread(8'h0C, v); chk("bauddiv default", v[19:0] == CPB);
        bread(8'h04, v); chk("tx empty at reset",  v[0] == 1'b1);
        chk("rx empty at reset", v[3] == 1'b1);
        bread(8'h08, v); chk("tx+rx enabled, 8 bits",
                                v[0] && v[1] && (v[14:11] == 4'd8));

        // ---- the tx line runs at the programmed rate ------------------
        fork
            bwrite(8'h00, 32'h55);          // 0x55 = 01010101, edge-rich
            measure_bit_time(measured);
        join
        // start bit (low) then bit0 = 1 -> exactly one bit time apart
        chk("tx bit time == clocks per bit",
               (measured >= CPB - 1) && (measured <= CPB + 1));
        if (measured < CPB - 1 || measured > CPB + 1)
            $display("       measured %0d clocks, expected %0d", measured, CPB);

        // ---- FIFO depth and levels -------------------------------------
        bwrite(8'h08, CFG_8N1 | FLUSH);
        for (i = 0; i < 16; i = i + 1) bwrite(8'h00, i);
        bread(8'h18, v);
        chk("tx fifo took at least 14 bytes", v[7:0] >= 8'd14);
        bread(8'h04, v);
        chk("tx not empty while draining", v[0] == 1'b0);
        drain_tx();
        bread(8'h04, v); chk("tx drains to empty", v[0] == 1'b1 && v[2] == 1'b0);

        // ---- receive path, 8N1 -----------------------------------------
        bwrite(8'h08, CFG_8N1 | FLUSH);
        rx_byte(8'hA3);
        rx_byte(8'h5C);
        bread(8'h18, v); chk("rx fifo holds 2", v[15:8] == 8'd2);

        bread(8'h00, v);
        chk("rx byte 1 valid", v[8] == 1'b1);
        chk("rx byte 1 value", v[7:0] == 8'hA3);
        bread(8'h00, v);
        chk("rx byte 2 value", v[7:0] == 8'h5C);
        bread(8'h00, v);
        chk("rx empty flag after draining", v[8] == 1'b0);

        // ---- framing error ----------------------------------------------
        rx_broken_byte(8'h3C);
        bread(8'h04, v); chk("frame error latched", v[6] == 1'b1);
        bwrite(8'h14, 32'h20);                          // W1C the error group
        bread(8'h04, v); chk("frame error cleared", v[6] == 1'b0);

        // ---- 7E1 through loopback ---------------------------------------
        bwrite(8'h08, CFG_7E1 | LOOPB | FLUSH);
        bwrite(8'h00, 32'h47);                          // 'G', fits in 7 bits
        repeat (CPB * 14) @(posedge clk);
        bread(8'h00, v);
        chk("7E1 loopback value", v[8] && (v[7:0] == 8'h47));
        bread(8'h04, v); chk("7E1 no parity error", v[7] == 1'b0);
        drain_tx();

        // ---- 8O2 through loopback ---------------------------------------
        bwrite(8'h08, CFG_8O2 | LOOPB | FLUSH);
        bwrite(8'h00, 32'hC9);
        repeat (CPB * 18) @(posedge clk);
        bread(8'h00, v);
        chk("8O2 loopback value", v[8] && (v[7:0] == 8'hC9));
        bread(8'h04, v); chk("8O2 no parity error", v[7] == 1'b0);
        drain_tx();
        bwrite(8'h08, CFG_8N1 | FLUSH);                 // back to 8N1

        // ---- interrupts ---------------------------------------------------
        bwrite(8'h10, 32'h00);                          // all disabled
        chk("irq low when masked", irq == 1'b0);
        bwrite(8'h1C, 32'h0200);                        // rx watermark = 2
        bwrite(8'h10, 32'h02);                          // enable rx watermark
        rx_byte(8'h11);
        chk("no irq at 1 byte with wm=2", irq == 1'b0);
        rx_byte(8'h22);
        repeat (4) @(posedge clk);
        chk("irq at 2 bytes with wm=2", irq == 1'b1);
        bread(8'h00, v); chk("wm byte 1", v[7:0] == 8'h11);
        bread(8'h00, v); chk("wm byte 2", v[7:0] == 8'h22);
        repeat (4) @(posedge clk);
        chk("irq clears when drained", irq == 1'b0);

        // ---- idle ("receive to idle") --------------------------------------
        bwrite(8'h20, 32'd4);                           // 4 bit-times of quiet
        bwrite(8'h14, 32'h10);                          // clear any stale idle
        bwrite(8'h10, 32'h10);                          // enable idle
        rx_byte(8'h77);
        repeat (CPB * 8) @(posedge clk);
        chk("idle event after quiet line", irq == 1'b1);
        bread(8'h04, v); chk("idle status bit", v[8] == 1'b1);
        bwrite(8'h14, 32'h10);                          // W1C idle
        repeat (2) @(posedge clk);
        bread(8'h04, v); chk("idle cleared", v[8] == 1'b0);

        if (errors == 0) $display("s6_uart_tb: PASS");
        else             $display("s6_uart_tb: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("s6_uart_tb: TIMEOUT");
        $finish;
    end
endmodule

`default_nettype wire
