`timescale 1ns/1ps
`default_nettype none
module clint_tb;
    reg clk=0, rst=1, sel=0, we=0; reg [7:0] addr=0; reg [31:0] wdata=0;
    wire [31:0] rdata; wire irq;
    clint dut(.clk(clk),.rst(rst),.sel(sel),.we(we),.addr(addr),.wdata(wdata),.rdata(rdata),.irq(irq));
    always #5 clk=~clk;
    task wr(input [7:0] a, input [31:0] d); begin @(negedge clk); sel=1; we=1; addr=a; wdata=d; @(negedge clk); sel=0; we=0; end endtask
    task rd(input [7:0] a); begin @(negedge clk); sel=1; we=0; addr=a; #1; end endtask
    initial begin
        repeat(2) @(posedge clk); #1; rst=0;
        repeat(20) @(posedge clk);
        rd(8'h0); $display("mtime_lo after ~20 ticks = %0d (irq=%b, want irq=0 since cmp=MAX)", rdata, irq);
        wr(8'hC, 32'd0); wr(8'h8, 32'd30);    // mtimecmp = 30
        rd(8'h8); $display("mtimecmp_lo = %0d", rdata);
        repeat(20) @(posedge clk); #1;
        $display("after passing 30: irq=%b (want 1)", irq);
        wr(8'h8, 32'hFFFF_FFFF); wr(8'hC, 32'hFFFF_FFFF);  // disarm
        #1 $display("after disarm: irq=%b (want 0)", irq);
        // 64-bit rollover check: force high compare reachable quickly is impractical;
        // just confirm high word reads back
        rd(8'h4); $display("mtime_hi = %0d (want 0 this early)", rdata);
        $finish;
    end
endmodule
`default_nettype wire
