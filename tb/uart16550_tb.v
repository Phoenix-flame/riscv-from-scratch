`timescale 1ns/1ps
`default_nettype none
// =====================================================================
// uart16550_tb.v  -  register-level test of the ns16550a-compatible UART
// ---------------------------------------------------------------------
// Drives the register interface the way a driver does (LCR/DLAB, FCR,
// IER, LSR polling) and checks the serial lines against an independent
// bit-banged model in this testbench: transmit framing for 8N1, 7E2,
// 8O1, the divisor, both 16-deep FIFOs, overrun, parity / framing
// errors, the four interrupt sources in priority order with their
// acknowledge rules, and loopback.
// =====================================================================
module uart16550_tb;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         sel = 0, we = 0;
    reg  [4:0]  addr = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] rdata;
    reg         rx = 1;
    wire        tx, irq;

    uart16550 dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .addr(addr),
                   .wdata(wdata), .rdata(rdata), .rx(rx), .tx(tx), .irq(irq));

    localparam THR=0, RBR=0, DLL=0, IER=1, DLM=1, IIR=2, FCR=2, LCR=3, MCR=4, LSR=5, MSR=6, SCR=7;
    integer fails = 0, cpb = 16;

    // ---- bus cycles, one register access per clock as the core does ----
    task wr; input [2:0] r; input [7:0] v; begin
        @(negedge clk); sel = 1; we = 1; addr = {r, 2'b00}; wdata = {24'd0, v};
        @(negedge clk); sel = 0; we = 0;
    end endtask
    reg [7:0] rv;
    task rdr; input [2:0] r; begin
        @(negedge clk); sel = 1; we = 0; addr = {r, 2'b00}; #1 rv = rdata[7:0];
        @(negedge clk); sel = 0;
    end endtask
    task rcheck; input [2:0] r; input [7:0] v; input [8*56-1:0] what; begin
        rdr(r);
        if (rv !== v) begin
            $display("  FAIL %0s: read %02h, expected %02h", what, rv, v); fails = fails + 1;
        end else $display("  ok   %0s = %02h", what, rv);
    end endtask
    task check; input c; input [8*48-1:0] what; begin
        if (!c) begin $display("  FAIL %0s", what); fails = fails + 1; end
        else         $display("  ok   %0s", what);
    end endtask

    // ---- the line model: send one character on rx ----
    task send_char; input [7:0] d; input integer nbits; input integer par; // 0 none 1 odd 2 even
                    input integer nstop; input bad_stop; integer i; reg p; begin
        p = 0;
        rx = 0; repeat (cpb) @(posedge clk);
        for (i = 0; i < nbits; i = i + 1) begin rx = d[i]; p = p ^ d[i]; repeat (cpb) @(posedge clk); end
        if (par != 0) begin rx = (par == 2) ? p : ~p; repeat (cpb) @(posedge clk); end
        rx = bad_stop ? 1'b0 : 1'b1; repeat (cpb) @(posedge clk);
        rx = 1; repeat (cpb * (nstop - 1) + cpb / 2) @(posedge clk);
    end endtask
    task send_bad_parity; input [7:0] d; integer i; reg p; begin           // 8E1, wrong parity
        p = 0; rx = 0; repeat (cpb) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin rx = d[i]; p = p ^ d[i]; repeat (cpb) @(posedge clk); end
        rx = ~p; repeat (cpb) @(posedge clk);
        rx = 1; repeat (cpb + cpb / 2) @(posedge clk);
    end endtask

    // ---- ... and receive one from tx, checking the framing ----
    reg [7:0] got; reg frame_ok;
    task recv_char; input integer nbits; input integer par; input integer nstop;
                    integer i, g; reg p; begin
        g = 0; while (tx === 1'b1 && g < 100000) begin @(posedge clk); g = g + 1; end
        repeat (cpb / 2) @(posedge clk);                    // middle of the start bit
        frame_ok = (tx === 1'b0); got = 0; p = 0;
        for (i = 0; i < nbits; i = i + 1) begin
            repeat (cpb) @(posedge clk); got[i] = tx; p = p ^ tx;
        end
        if (par != 0) begin
            repeat (cpb) @(posedge clk);
            if (tx !== ((par == 2) ? p : ~p)) frame_ok = 0;
        end
        for (i = 0; i < nstop; i = i + 1) begin
            repeat (cpb) @(posedge clk); if (tx !== 1'b1) frame_ok = 0;
        end
    end endtask

    integer n, t0, t1;
    initial begin
        repeat (3) @(posedge clk); #1 rst = 0;

        $display("---- reset state ----");
        rcheck(IIR, 8'h01, "IIR (no interrupt, FIFOs off)");
        rcheck(LSR, 8'h60, "LSR (THRE | TEMT)");
        rcheck(MSR, 8'hB0, "MSR (CTS | DSR | DCD)");
        wr(SCR, 8'h5A); rcheck(SCR, 8'h5A, "SCR scratch");

        $display("---- divisor latch + 8N1 transmit ----");
        wr(LCR, 8'h83); wr(DLL, 8'h02); wr(DLM, 8'h00);
        rcheck(DLL, 8'h02, "DLL (DLAB=1)");
        wr(LCR, 8'h03); cpb = 32;
        rcheck(LCR, 8'h03, "LCR 8N1");
        rcheck(IER, 8'h00, "IER with DLAB=0 (not DLM)");
        wr(FCR, 8'h07);
        rcheck(IIR, 8'hC1, "IIR (FIFOs on)");
        fork
            begin wr(THR, 8'h52); wr(THR, 8'h56); wr(THR, 8'h0A); end
            begin
                recv_char(8, 0, 1); check(got == 8'h52 && frame_ok, "tx 'R' 8N1 at 32 clocks/bit");
                t0 = $time;
                recv_char(8, 0, 1); check(got == 8'h56 && frame_ok, "tx 'V'");
                t1 = $time;
                recv_char(8, 0, 1); check(got == 8'h0A && frame_ok, "tx LF");
            end
        join
        check((t1 - t0) >= 3200 && (t1 - t0) <= 3220, "back-to-back characters: 10 bit times apart");
        $display("       (%0d ns = %0d clocks between frames)", t1 - t0, (t1 - t0) / 10);
        repeat (40) @(posedge clk);
        rcheck(LSR, 8'h60, "LSR after the FIFO drained");

        $display("---- 7E2 and 8O1 framing ----");
        wr(LCR, 8'h1E);                                      // 7 bits, 2 stop, even
        fork wr(THR, 8'h35); begin recv_char(7, 2, 2); check(got == 8'h35 && frame_ok, "tx 7E2"); end join
        wr(LCR, 8'h0B);                                      // 8 bits, 1 stop, odd
        fork wr(THR, 8'hC3); begin recv_char(8, 1, 1); check(got == 8'hC3 && frame_ok, "tx 8O1"); end join
        repeat (40) @(posedge clk);
        wr(LCR, 8'h03);

        $display("---- receive, FIFO, trigger level, timeout ----");
        wr(FCR, 8'h47);                                      // FIFOs on, cleared, trigger 4
        wr(IER, 8'h01);                                      // rx data interrupt
        send_char(8'h11, 8, 0, 1, 0); send_char(8'h22, 8, 0, 1, 0); send_char(8'h33, 8, 0, 1, 0);
        rcheck(LSR, 8'h61, "LSR data ready");
        check(irq == 1'b0, "3 bytes < trigger 4: no interrupt yet");
        send_char(8'h44, 8, 0, 1, 0);
        check(irq == 1'b1, "4th byte reaches the trigger: irq");
        rcheck(IIR, 8'hC4, "IIR = rx data available");
        rcheck(RBR, 8'h11, "RBR 1st"); rcheck(RBR, 8'h22, "RBR 2nd");
        check(irq == 1'b0, "below the trigger again: irq drops");
        repeat (40 * 32 + 10) @(posedge clk);
        check(irq == 1'b1, "~4 character times with data waiting: timeout irq");
        rcheck(IIR, 8'hCC, "IIR = character timeout");
        rcheck(RBR, 8'h33, "RBR 3rd"); rcheck(RBR, 8'h44, "RBR 4th");
        rcheck(LSR, 8'h60, "LSR empty again");
        check(irq == 1'b0, "FIFO empty: no interrupt");

        $display("---- overrun ----");
        wr(IER, 8'h00);
        for (n = 0; n < 17; n = n + 1) send_char(8'h80 + n, 8, 0, 1, 0);
        rcheck(LSR, 8'h63, "LSR data ready + overrun");
        rcheck(LSR, 8'h61, "overrun cleared by reading LSR");
        rv = 0;
        for (n = 0; n < 16; n = n + 1) begin rdr(RBR); if (rv != 8'h80 + n) rv = 8'hEE; end
        check(rv != 8'hEE, "the first 16 bytes kept, in order; the 17th dropped");
        rcheck(LSR, 8'h60, "LSR empty");

        $display("---- parity / framing errors, line-status interrupt ----");
        wr(LCR, 8'h1B);                                      // 8E1
        wr(IER, 8'h05);                                      // rx data + line status
        send_bad_parity(8'hA5);
        check(irq == 1'b1, "parity error: irq");
        rcheck(IIR, 8'hC6, "IIR = line status (beats rx data)");
        rcheck(LSR, 8'hE5, "LSR: FIFO error, parity error, data ready");
        rcheck(IIR, 8'hC1, "after LSR read: none (1 byte < trigger 4)");
        rcheck(RBR, 8'hA5, "the byte itself still arrives");
        wr(LCR, 8'h03);
        send_char(8'h5C, 8, 0, 1, 1);                        // stop bit low
        rcheck(LSR, 8'hE9, "LSR: framing error");
        rcheck(RBR, 8'h5C, "RBR after framing error");
        wr(IER, 8'h00);

        $display("---- THR-empty interrupt ----");
        wr(IER, 8'h02);
        check(irq == 1'b1, "enabling ETBEI with an empty FIFO raises it");
        rcheck(IIR, 8'hC2, "IIR = THR empty");
        check(irq == 1'b0, "reading IIR acknowledged it");
        fork wr(THR, 8'h21); recv_char(8, 0, 1); join
        check(got == 8'h21 && irq == 1'b1, "FIFO drained again: THR-empty irq");
        wr(THR, 8'h22);
        check(irq == 1'b0, "writing THR clears it");
        recv_char(8, 0, 1);
        wr(IER, 8'h00);
        repeat (40) @(posedge clk);

        $display("---- loopback ----");
        wr(MCR, 8'h1B);                                      // loop, OUT2, RTS, DTR
        rcheck(MSR, 8'hB0, "MSR in loopback: DCD=OUT2 DSR=DTR CTS=RTS");
        wr(THR, 8'h7E);
        n = 0; rv = 0;
        while (n < 2000 && !(rv & 1)) begin rdr(LSR); n = n + 1; end
        check(tx === 1'b1, "tx pin idles high in loopback");
        rcheck(RBR, 8'h7E, "byte came back through the internal loop");
        wr(MCR, 8'h00);

        if (fails == 0) $display("UART16550: ALL PASS");
        else            $display("UART16550: %0d FAIL", fails);
        $finish;
    end
    initial begin #50000000; $display("UART16550: TIMEOUT"); $finish; end
endmodule
`default_nettype wire
