`timescale 1ns/1ps
`default_nettype none
// Step 47: run a tools/vtest program on soc_pipe_u and dump data memory
// 0x2000..0x5fff to +DUMP= (one word per line) for comparison with the model.
// With -DCACHED: on soc_pipe_c instead -- I/D caches over slow memory, so
// the vector unit's D-port requests wait on misses, refills and evictions.
module vec_diff_tb;
    parameter VLEN = 128;
    reg clk=0, rst=1; wire tx, halted;
    always #5 clk = ~clk;
`ifdef CACHED
    soc_pipe_c #(.LATENCY(7), .D_LINES(16), .ROM_WORDS(4096), .RAM_WORDS(8192),
                 .CLKS_PER_BIT(4), .VLEN(VLEN)) dut (
        .clk(clk), .rst(rst), .uart_tx_pin(tx), .halted(halted));
    `define ROM dut.u_imem.mem
    `define RAM dut.u_dmem.mem
    `define PEEK(a) dut.g_cache.peek(a)
`else
    soc_pipe_u #(.ROM_WORDS(4096), .RAM_WORDS(8192), .CLKS_PER_BIT(4), .VLEN(VLEN)) dut (
        .clk(clk), .rst(rst), .uart_tx_pin(tx), .halted(halted));
    `define ROM dut.rom
    `define RAM dut.ram
    `define PEEK(a) dut.ram[(a) >> 2]
`endif
    reg [1023:0] romf, dumpf;
    integer cyc=0, i, fd;
    always @(posedge clk) if (!rst && !halted) cyc = cyc + 1;
    initial begin
        #1;                                   // after the memories' own initial blocks
        for (i = 0; i < 8192; i = i + 1) `RAM[i] = 32'd0;
        if (!$value$plusargs("ROM=%s", romf)) begin $display("need +ROM="); $finish; end
        $readmemh(romf, `ROM);
        $readmemh(romf, `RAM);
        repeat(3) @(posedge clk); #1; rst=0;
        while (!halted && cyc < 4000000) @(posedge clk);
        #1;
        if (!halted) $display("VEC: did not halt (pc %h)", dut.u_core.pc);
        else $display("VEC: halted after %0d cycles", cyc);
        if ($value$plusargs("DUMP=%s", dumpf)) begin
            fd = $fopen(dumpf, "w");
            for (i = 'h2000/4; i < 'h6000/4; i = i + 1) $fwrite(fd, "%h\n", `PEEK(4 * i));
            $fclose(fd);
        end
        $finish;
    end
endmodule
`default_nettype wire
