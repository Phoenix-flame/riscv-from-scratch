`timescale 1ns/1ps
`default_nettype none
// Generic program check for soc_pipe_u: load +ROM= (and optionally +RAM=)
// word images, run to the SYSCON halt, and compare everything the program
// printed on the UART byte-for-byte against +EXPECT= (a text file).
module pipe_u_prog_tb;
    reg clk=0, rst=1; wire tx, halted;
    always #5 clk = ~clk;

    soc_pipe_u #(.ROM_WORDS(4096), .RAM_WORDS(8192), .CLKS_PER_BIT(4)) dut (
        .clk(clk), .rst(rst), .uart_tx_pin(tx), .halted(halted));

    reg [1023:0] romf, ramf, expf;
    integer fd, ch, nout=0, nbad=0, cyc=0, ret=0, fails=0;
    reg [7:0] outbuf [0:65535];

    always @(posedge clk)
        if (!rst && dut.sel_uart && dut.wr_any && (dut.daddr[7:0]==8'h00)) begin
            $write("%c", dut.dwdata[7:0]);
            outbuf[nout] = dut.dwdata[7:0]; nout = nout + 1;
        end
    always @(posedge clk) if (!rst && !halted) begin
        cyc = cyc + 1; if (dut.retire) ret = ret + 1;
    end

    initial begin
        if (!$value$plusargs("ROM=%s", romf)) begin $display("need +ROM="); $finish; end
        $readmemh(romf, dut.rom);
        if ($value$plusargs("RAM=%s", ramf)) $readmemh(ramf, dut.ram);
        repeat(3) @(posedge clk); #1; rst=0;
        while (!halted && cyc < 2000000) @(posedge clk);
        #1;
        if (!halted) begin $write("FAIL: did not halt\n"); fails=fails+1; end
        if ($value$plusargs("EXPECT=%s", expf)) begin
            fd = $fopen(expf, "r");
            begin : cmp integer i;
                for (i = 0; i < nout; i = i + 1) begin
                    ch = $fgetc(fd);
                    if (ch != outbuf[i] && nbad == 0) begin
                        $write("FAIL: output byte %0d is %h, expected %h\n", i, outbuf[i], ch);
                        nbad = nbad + 1;
                    end
                end
                if ($fgetc(fd) != -1) begin $write("FAIL: output ends early (%0d bytes)\n", nout); nbad=nbad+1; end
            end
            $fclose(fd);
            fails = fails + nbad;
        end
        $write("  cycles %0d  retired %0d  (CPI %0d.%02d)\n", cyc, ret, cyc/ret, (cyc*100/ret)%100);
        if (fails==0) $write("PIPE-U PROG: PASS (%0d bytes match)\n", nout);
        else          $write("PIPE-U PROG: FAIL\n");
        $finish;
    end
endmodule
`default_nettype wire
