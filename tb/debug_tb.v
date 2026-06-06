`timescale 1ns/1ps
`default_nettype none
module debug_tb;
    reg clk=0, rst=1;
    reg        dmi_sel=0, dmi_we=0;
    reg  [7:0] dmi_addr=0;
    reg [31:0] dmi_wdata=0;
    wire [31:0] dmi_rdata, pc;
    soc_dbg #(.INIT_FILE("sw/dbg.hex"), .IMEM_WORDS(1024), .RAM_BYTES(4096)) dut (
        .clk(clk), .rst(rst), .pc_out(pc),
        .dmi_sel(dmi_sel), .dmi_we(dmi_we), .dmi_addr(dmi_addr),
        .dmi_wdata(dmi_wdata), .dmi_rdata(dmi_rdata));
    always #5 clk = ~clk;

    task dwr(input [7:0] a, input [31:0] d); begin
        @(negedge clk); dmi_sel=1; dmi_we=1; dmi_addr=a; dmi_wdata=d;
        @(posedge clk); #1; dmi_sel=0; dmi_we=0;
    end endtask
    task drd(input [7:0] a, output [31:0] d); begin
        dmi_sel=1; dmi_we=0; dmi_addr=a; #1; d=dmi_rdata; dmi_sel=0;
    end endtask
    task wait_halt; integer n; reg [31:0] s; begin
        n=0; drd(8'h04,s);
        while(!(s & 1) && n<200) begin @(posedge clk); drd(8'h04,s); n=n+1; end
    end endtask
    task rdreg(input [4:0] r, output [31:0] d); begin dwr(8'h08,r); drd(8'h0C,d); end endtask
    task rdmem(input [31:0] a, output [31:0] d); begin dwr(8'h14,a); drd(8'h18,d); end endtask

    integer i; reg [31:0] vpc, va5, vc, vt, v6, vm;
    initial begin
        repeat(3) @(posedge clk); #1; rst=0;
        repeat(400) @(posedge clk);

        $display("=== HALT ===");
        dwr(8'h00, 32'h1); wait_halt();
        drd(8'h10,vpc); rdreg(15,va5); rdmem(32'h7ac,vc); rdmem(32'h7a8,vt);
        $display("halted at pc=0x%08h", vpc);
        $display("a5 (loop index i) = %0d", va5);
        $display("counter@0x7ac=%0d  total@0x7a8=%0d", vc, vt);

        $display("=== SINGLE-STEP x6 (PC walks the loop) ===");
        for (i=0;i<6;i=i+1) begin
            dwr(8'h00, 32'h4); wait_halt(); drd(8'h10,vpc);
            $display("  step %0d -> pc=0x%08h", i, vpc);
        end

        $display("=== HARDWARE BREAKPOINT @0x618 ===");
        dwr(8'h1C,32'h0); dwr(8'h20,32'h618);
        dwr(8'h00,32'h2); wait_halt(); drd(8'h10,vpc); rdreg(15,va5);
        $display("hit bp: pc=0x%08h  i=%0d", vpc, va5);
        dwr(8'h00,32'h2); wait_halt(); drd(8'h10,vpc); rdreg(15,va5);
        $display("hit bp: pc=0x%08h  i=%0d  (advanced one iteration)", vpc, va5);

        $display("=== WRITE reg + mem, read back ===");
        dwr(8'h08,32'd6); dwr(8'h0C,32'hDEADBEEF); rdreg(6,v6);
        $display("x6  <- 0xDEADBEEF, read back 0x%08h", v6);
        dwr(8'h14,32'h300); dwr(8'h18,32'h0000CAFE); rdmem(32'h300,vm);
        $display("mem[0x300] <- 0xCAFE, read back 0x%08h", vm);

        $display("=== resume to completion (clear bp, fast-forward i) ===");
        dwr(8'h1C,32'h0); dwr(8'h24,32'h0);
        dwr(8'h08,32'd15); dwr(8'h0C,32'h00030D40);
        dwr(8'h00,32'h2);
        repeat(3000) @(posedge clk);
        $display("[tb] window elapsed"); $finish;
    end
endmodule
`default_nettype wire
