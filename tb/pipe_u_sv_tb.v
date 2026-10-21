`timescale 1ns/1ps
`default_nettype none
// Step 44: an S-mode kernel running translated and handling its user
// program's page faults (sw/sv_demo.c + sw/sv_asm.S) on the unified pipeline.
// Checks, from the kernel's mailbox and the physical pages:
//   SUM      - S reading a U page faults (from S, to S) until SUM=1
//   demand   - a U store to unmapped VA 0x5008 is a store fault (15) taken
//              in S with stval = 0x5008; S maps the page and the store retries
//   fetch    - a U jump to a non-executable page is cause 12 in S,
//              stval = sepc = 0x6000
//   M        - sees exactly one trap: the S kernel's shutdown ecall (cause 9)
module pipe_u_sv_tb;
    reg clk=0, rst=1; wire tx, halted;
    always #5 clk = ~clk;
    soc_pipe_u #(.ROM_WORDS(4096), .RAM_WORDS(16384),
                 .IMEM_INIT("sw/sv.hex"), .CLKS_PER_BIT(4)) dut (
        .clk(clk), .rst(rst), .uart_tx_pin(tx), .halted(halted));

    always @(posedge clk)
        if (!rst && dut.sel_uart && dut.wr_any && (dut.daddr[7:0]==8'h00))
            $write("%c", dut.dwdata[7:0]);

    function [31:0] rd; input [31:0] pa; rd = dut.ram[pa>>2]; endfunction
    integer fails = 0, cyc = 0;
    always @(posedge clk) if (!rst && !halted) cyc = cyc + 1;
    task want_eq; input [8*28:1] what; input [31:0] got, want;
        if (got !== want) begin $write("\nFAIL: %0s = %h, want %h", what, got, want); fails = fails + 1; end
    endtask

    initial begin
        $write("---- Step 44: S-mode kernel, translated, serving user page faults ----\n");
        repeat(3) @(posedge clk); #1; rst=0;
        while (!halted && cyc < 200000) @(posedge clk);
        #1;
        if (!halted) begin $write("\nFAIL: did not halt"); fails = fails + 1; end
        want_eq("SUM=0 read of U page",   rd(32'h7F00), 32'h0);
        want_eq("SUM=1 read of U page",   rd(32'h7F04), 32'h5A5A5A5A);
        want_eq("S->S load faults",       rd(32'h7F08), 32'd1);
        want_eq("  their stval",          rd(32'h7F0C), 32'h4000);
        want_eq("demand faults",          rd(32'h7F10), 32'd1);
        want_eq("  stval",                rd(32'h7F14), 32'h5008);
        want_eq("  scause",               rd(32'h7F18), 32'd15);
        want_eq("fetch fault stval",      rd(32'h7F1C), 32'h6000);
        want_eq("fetch fault sepc",       rd(32'h7F20), 32'h6000);
        want_eq("M shutdown ecalls",      rd(32'h7F24), 32'd1);
        want_eq("M saw other",            rd(32'h7F28), 32'd0);
        want_eq("user ecalls",            rd(32'h7F2C), 32'd2);
        want_eq("user wrote PA 0x4004",   rd(32'h4004), 32'h5A5A5A5B);
        want_eq("demand page PA 0x5008",  rd(32'h5008), 32'hD00D);
        want_eq("readback PA 0x4008",     rd(32'h4008), 32'hD00D);
        $write("\n  %0d cycles\n", cyc);
        if (fails == 0) $write("PIPE-U SV: ALL PASS (SUM, demand paging, fetch fault -- all handled in S)\n");
        else            $write("PIPE-U SV: %0d FAIL\n", fails);
        $finish;
    end
endmodule
`default_nettype wire
