`timescale 1ns/1ps
`default_nettype none
// Runs the compiled picolibc program on soc_libc and checks the bytes it
// transmits over the UART against tb/libc_expected.hex (the exact expected
// output, LF cooked to CRLF). Self-checking: snoops every TX write, then
// compares the captured stream byte-for-byte. Also confirms the core halted.
module libc_tb;
    reg clk=0, rst=1; always #5 clk=~clk;
    wire halted;

    soc_libc #(.ROM_WORDS(8192), .RAM_WORDS(16384),
               .IMEM_INIT("sw/libc_demo.hex"),
               .DMEM_INIT("sw/libc_demo.hex")) dut (
        .clk(clk), .rst(rst), .halted(halted)
    );

    // snoop UART TX writes (offset 0)
    reg [7:0] cap [0:4095];
    integer ncap = 0;
    always @(posedge clk)
        if (!rst && dut.sel_uart && (|dut.dwe) && (dut.daddr[3:0]==4'h0)) begin
            cap[ncap] = dut.dwdata[7:0];
            ncap = ncap + 1;
        end

    reg [7:0] exp [0:4095];
    integer nexp, i, g, fails;

    initial begin
        // count expected bytes
        for (i=0;i<4096;i=i+1) exp[i] = 8'hxx;
        $readmemh("tb/libc_expected.hex", exp);
        nexp = 0;
        for (i=0;i<4096;i=i+1) if (exp[i]!==8'hxx) nexp = i+1;

        repeat(3) @(posedge clk); #1; rst=0;
        g=0; while(!halted && g<5000000) begin @(posedge clk); g=g+1; end

        fails = 0;
        if (!halted) begin $display("FAIL: core did not halt"); fails=fails+1; end
        if (ncap !== nexp) begin
            $display("FAIL: byte count got=%0d exp=%0d", ncap, nexp); fails=fails+1;
        end
        for (i=0; i<nexp && i<ncap; i=i+1)
            if (cap[i] !== exp[i]) begin
                fails=fails+1;
                if (fails<=8) $display("FAIL byte %0d: got %02h exp %02h", i, cap[i], exp[i]);
            end

        $display("");
        $display("captured %0d UART bytes (expected %0d), halt @ %0d cycles", ncap, nexp, g);
        if (fails==0) $display("LIBC: ALL PASS");
        else          $display("LIBC: %0d FAIL", fails);
        $finish;
    end
endmodule
`default_nettype wire
