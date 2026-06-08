`timescale 1ns/1ps
`default_nettype none
// Drives the PLIC SoC: pulses three external interrupt lines and checks that
// the firmware's ISR claims them in priority order, then raises the threshold
// and checks that the low-priority source is masked (stays pending).
module plic_tb;
    reg clk=0, rst=1; always #5 clk=~clk;
    reg [3:1] irq_ext; reg uart_rx=1; wire uart_tx, halted;

    soc_plic #(.ROM_WORDS(4096), .RAM_WORDS(4096),
               .IMEM_INIT("sw/plic_demo.hex"), .DMEM_INIT("sw/plic_demo.hex")) dut (
        .clk(clk), .rst(rst), .uart_rx_pin(uart_rx), .uart_tx_pin(uart_tx),
        .irq_ext(irq_ext), .halted(halted));

    // RAM is word-addressed: byte A -> mem[A>>2]
    function [31:0] rd; input [31:0] a; rd = dut.u_ram.mem[a>>2]; endfunction

    task wait_for; input [31:0] a; input [31:0] val; integer g; begin
        g=0; while (rd(a)!==val && g<500000) begin @(posedge clk); g=g+1; end
    end endtask

    task pulse_lines; begin            // assert all three external lines for 1 cycle
        @(negedge clk); irq_ext=3'b111;
        @(negedge clk); irq_ext=3'b000;
    end endtask

    integer fails=0;
    initial begin
        irq_ext=0;
        repeat(3) @(posedge clk); #1; rst=0;

        // ---- phase 1: priority ordering ----
        wait_for(32'h800, 32'd1);                 // firmware configured + READY
        pulse_lines();
        wait_for(32'h804, 32'd1);                 // P1DONE
        $display("=== PLIC: several lines -> one MEIP, claimed by priority ===");
        $display(" priorities: src2=3 src3=7 src4=5  (all pulsed together)");
        $display(" claim order: %0d, %0d, %0d  (expect 3, 4, 2)",
                 rd(32'h810), rd(32'h814), rd(32'h818));
        if (rd(32'h810)!==32'd3 || rd(32'h814)!==32'd4 || rd(32'h818)!==32'd2) fails=fails+1;

        // ---- phase 2: threshold masks the low-priority source ----
        wait_for(32'h808, 32'd1);                 // P2READY (threshold now 4)
        pulse_lines();
        wait_for(32'h80C, 32'h0000_600D);         // DONE
        $display("");
        $display(" threshold=4: only src3(7) and src4(5) admitted, src2(3) masked");
        $display(" claim order: %0d, %0d  (expect 3, 4)", rd(32'h820), rd(32'h824));
        $display(" PLIC pending after: 0x%0h  (expect bit1<<2 = 0x4, src2 still pending)",
                 rd(32'h828));
        if (rd(32'h820)!==32'd3 || rd(32'h824)!==32'd4) fails=fails+1;
        if ((rd(32'h828) & 32'h4) == 0) fails=fails+1;   // src2 pending bit set

        $display("");
        if (fails==0) $display("PLIC: ALL PASS");
        else          $display("PLIC: %0d FAIL", fails);
        $finish;
    end
endmodule
`default_nettype wire
