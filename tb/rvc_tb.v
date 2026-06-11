`timescale 1ns/1ps
`default_nettype none
// Runs the same C program twice: compiled rv32im on the baseline multi-cycle
// SoC (soc_fpga / cpu_mc), and compiled rv32imc on the compressed-instruction
// SoC (soc_c / cpu_mc_c). Both must produce the same checksum and the same
// trap count (4 ecall round-trips through compressed code). The testbench
// also counts, on the C core, how many compressed instructions executed and
// how many word-straddling fetches (S_FETCH2 detours) occurred -- proving the
// unaligned path was genuinely exercised, not just compiled in.
module rvc_tb;
    reg clk=0, rst=1; always #5 clk=~clk;

    // ---- baseline: rv32im on cpu_mc ----
    wire im_halted, im_tx;
    soc_fpga #(.ROM_WORDS(4096), .RAM_WORDS(4096),
               .IMEM_INIT("sw/rvc_demo_im.hex"), .DMEM_INIT("sw/rvc_demo_im.hex")) dut_im (
        .clk(clk), .rst(rst), .uart_tx_pin(im_tx), .halted(im_halted));

    // ---- compressed: rv32imc on cpu_mc_c ----
    wire c_halted;
    soc_c #(.ROM_WORDS(4096), .RAM_WORDS(4096),
            .IMEM_INIT("sw/rvc_demo.hex"), .DMEM_INIT("sw/rvc_demo.hex")) dut_c (
        .clk(clk), .rst(rst), .halted(c_halted));

    function [31:0] rd_im; input [31:0] a; rd_im = dut_im.u_ram.mem[a>>2]; endfunction
    function [31:0] rd_c;  input [31:0] a; rd_c  = dut_c.u_ram.mem[a>>2];  endfunction

    // cycle + fetch statistics
    reg [31:0] im_cyc=0, c_cyc=0, c_compressed=0, c_straddles=0;
    always @(posedge clk) if (!rst) begin
        if (!im_halted) im_cyc <= im_cyc + 1;
        if (!c_halted) begin
            c_cyc <= c_cyc + 1;
            if (dut_c.u_core.state == 3'd1 && dut_c.u_core.is_c)
                c_compressed <= c_compressed + 1;          // compressed instr in EXEC
            if (dut_c.u_core.state == 3'd1 && dut_c.u_core.need_hi)
                c_straddles  <= c_straddles + 1;           // straddle discovery
        end
    end

    integer g, fails;
    initial begin
        repeat(3) @(posedge clk); #1; rst=0;
        g=0; while (!(im_halted && c_halted) && g<300000) begin @(posedge clk); g=g+1; end
        #1; fails=0;
        $display("=========== RV32IM vs RV32IMC: same program, two encodings ===========");
        $display(" checksum   : im=0x%08h  imc=0x%08h  %s",
                 rd_im(32'h800), rd_c(32'h800),
                 (rd_im(32'h800)===rd_c(32'h800)) ? "(match)" : "(MISMATCH!)");
        $display(" trap count : im=%0d  imc=%0d  (expect 4 ecall round-trips)",
                 rd_im(32'h804), rd_c(32'h804));
        $display(" sentinel   : im=0x%0h  imc=0x%0h  (expect 600d)", rd_im(32'h808), rd_c(32'h808));
        $display("");
        $display(" cycles                 : im=%0d  imc=%0d", im_cyc, c_cyc);
        $display(" compressed instrs run  : %0d", c_compressed);
        $display(" straddling fetches     : %0d  (1 extra cycle each: instr split across two words)",
                 c_straddles);
        if (!(im_halted && c_halted))                       fails=fails+1;
        if (rd_im(32'h800) !== rd_c(32'h800))               fails=fails+1;
        if (rd_im(32'h808)!==32'h600D || rd_c(32'h808)!==32'h600D) fails=fails+1;
        if (rd_im(32'h804)!==32'd4 || rd_c(32'h804)!==32'd4) fails=fails+1;
        if (c_compressed == 0)                              fails=fails+1;
        if (c_straddles == 0)                               fails=fails+1;
        $display("");
        if (fails==0) $display("RVC: ALL PASS");
        else          $display("RVC: %0d FAIL", fails);
        $finish;
    end
endmodule
`default_nettype wire
