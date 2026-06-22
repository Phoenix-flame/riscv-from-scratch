`timescale 1ns/1ps
`default_nettype none
// Supervisor mode + trap delegation. Boots M -> S -> U. Verifies, from the
// RAM cells the handlers write, that delegated traps reached the S-mode
// handler and the non-delegated one reached M -- i.e. medeleg/mideleg routed
// each trap to the right privilege:
//   s_ecall_cnt   - ecall-from-U (cause 8), delegated to S
//   s_swi_cnt     - supervisor software interrupt (cause 1), delegated to S
//   s_illegal_cnt - illegal instruction (cause 2), delegated to S
//   m_scall_cnt   - ecall-from-S (cause 9), NOT delegated -> reached M
//   m_bad         - set only if M ever saw a cause that should have gone to S
module smode_tb;
    reg clk=0, rst=1; wire tx, halted;
    soc_s #(.ROM_WORDS(2048), .RAM_WORDS(4096),
            .IMEM_INIT("sw/smode.hex"), .CLKS_PER_BIT(4)) dut (
        .clk(clk), .rst(rst), .uart_tx_pin(tx), .halted(halted));
    always #5 clk = ~clk;

    function [31:0] rd; input [31:0] a; rd = dut.u_ram.mem[a>>2]; endfunction
    integer dots=0, g, fails;

    always @(posedge clk)
        if (!rst && dut.sel_uart && dut.wr_any && (dut.daddr[7:0]==8'h00)) begin
            $write("%c", dut.dwdata[7:0]);
            if (dut.dwdata[7:0]==".") dots = dots + 1;
        end

    initial begin
        $write("---- supervisor mode + medeleg/mideleg delegation ----\n");
        repeat(3) @(posedge clk); #1; rst=0;
        g=0; while(!halted && g<1000000) begin @(posedge clk); #1; g=g+1; end
        $write("\n");

        fails=0;
        if (!halted)                 begin $write("FAIL: no halt\n");                              fails=fails+1; end
        if (rd(32'h400) !== 32'd8)   begin $write("FAIL s_ecall_cnt=%0d exp 8\n",  rd(32'h400));   fails=fails+1; end
        if (rd(32'h404) !== 32'd7)   begin $write("FAIL s_swi_cnt=%0d exp 7\n",    rd(32'h404));   fails=fails+1; end
        if (rd(32'h408) !== 32'd1)   begin $write("FAIL s_illegal_cnt=%0d exp 1\n",rd(32'h408));   fails=fails+1; end
        if (rd(32'h40C) !== 32'd1)   begin $write("FAIL m_scall_cnt=%0d exp 1\n",  rd(32'h40C));   fails=fails+1; end
        if (rd(32'h410) !== 32'd0)   begin $write("FAIL m_bad=%h (M saw a delegated cause!)\n", rd(32'h410)); fails=fails+1; end
        if (rd(32'h418) !== 32'd0)   begin $write("FAIL s_other=%h (unexpected S cause)\n", rd(32'h418)); fails=fails+1; end
        if (rd(32'h414) !== 32'd8)   begin $write("FAIL u_progress=%0d exp 8\n",   rd(32'h414));   fails=fails+1; end
        if (dots !== 8)              begin $write("FAIL dots=%0d exp 8\n", dots);                  fails=fails+1; end

        $write("\nU ecalls -> S : %0d   SSIP -> S : %0d   illegal -> S : %0d\n",
               rd(32'h400), rd(32'h404), rd(32'h408));
        $write("S ecall  -> M : %0d   M saw-delegated : %0d   (halt @ %0d cycles)\n",
               rd(32'h40C), rd(32'h410), g);
        if (fails==0) $write("SMODE: ALL PASS (delegation routes U/S traps correctly)\n");
        else          $write("SMODE: %0d FAIL\n", fails);
        $finish;
    end
endmodule
`default_nettype wire
