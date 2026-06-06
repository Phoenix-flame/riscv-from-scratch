`timescale 1ns/1ps
`default_nettype none
// Runs the same branchy benchmark on the predict-not-taken pipeline and on the
// BTB+2-bit-counter pipeline, and reports control-transfer / misprediction /
// cycle counts for each. "Done" is the sentinel 0x600D written to word 0x104;
// each core's metrics are latched the cycle it appears, so the final spin loop
// is excluded.
module bpred_tb;
    reg clk=0, rst=1; always #5 clk=~clk;

    // ---- not-taken baseline core ----
    wire [31:0] nt_pc, nt_instr;
    cpu_pipe #(.INIT_FILE("sw/bpred_bench.hex")) nt (
        .clk(clk), .rst(rst), .pc_out(nt_pc), .instr_out(nt_instr));

    // ---- predictor core ----
    wire [31:0] bp_pc, bp_instr, bp_cyc, bp_ctrl, bp_tak, bp_mis;
    cpu_pipe_bp #(.INIT_FILE("sw/bpred_bench.hex")) bp (
        .clk(clk), .rst(rst), .pc_out(bp_pc), .instr_out(bp_instr),
        .perf_cycles(bp_cyc), .perf_ctrl(bp_ctrl), .perf_taken(bp_tak),
        .perf_mispred(bp_mis));

    // done = word at byte 0x104 == 0x600D
    function [31:0] nt_word104; input dummy; begin
        nt_word104 = {nt.u_dmem.mem[32'h107], nt.u_dmem.mem[32'h106],
                      nt.u_dmem.mem[32'h105], nt.u_dmem.mem[32'h104]}; end
    endfunction
    function [31:0] bp_word104; input dummy; begin
        bp_word104 = {bp.u_dmem.mem[32'h107], bp.u_dmem.mem[32'h106],
                      bp.u_dmem.mem[32'h105], bp.u_dmem.mem[32'h104]}; end
    endfunction
    function [31:0] nt_word100; input dummy; begin
        nt_word100 = {nt.u_dmem.mem[32'h103], nt.u_dmem.mem[32'h102],
                      nt.u_dmem.mem[32'h101], nt.u_dmem.mem[32'h100]}; end
    endfunction
    function [31:0] bp_word100; input dummy; begin
        bp_word100 = {bp.u_dmem.mem[32'h103], bp.u_dmem.mem[32'h102],
                      bp.u_dmem.mem[32'h101], bp.u_dmem.mem[32'h100]}; end
    endfunction

    // not-taken core: count control transfers, taken (=flushes) and cycles
    reg [31:0] nt_cyc=0, nt_ctrl=0, nt_tak=0;
    reg nt_done=0, bp_done=0;
    reg [31:0] nt_res, bp_res;
    // snapshots of the predictor's free-running counters, taken at bp_done
    reg [31:0] bp_cyc_s=0, bp_ctrl_s=0, bp_tak_s=0, bp_mis_s=0;

    always @(posedge clk) if (!rst) begin
        if (!nt_done) begin
            nt_cyc <= nt_cyc + 1;
            if (nt.idex_branch | nt.idex_jump | nt.idex_jalr) nt_ctrl <= nt_ctrl + 1;
            if (nt.ex_taken) nt_tak <= nt_tak + 1;
            if (nt_word104(1'b0) == 32'h0000_600D) begin nt_done<=1; nt_res<=nt_word100(1'b0); end
        end
        if (!bp_done) begin
            if (bp_word104(1'b0) == 32'h0000_600D) begin
                bp_done<=1; bp_res<=bp_word100(1'b0);
                bp_cyc_s<=bp_cyc; bp_ctrl_s<=bp_ctrl; bp_tak_s<=bp_tak; bp_mis_s<=bp_mis;
            end
        end
    end

    integer guard;
    initial begin
        rst=1; repeat(3) @(posedge clk); #1; rst=0;
        guard=0;
        while (!(nt_done && bp_done) && guard<2_000_000) begin @(posedge clk); guard=guard+1; end
        #1;
        $display("================ branch-prediction comparison ================");
        $display(" benchmark: 30x60 nested loops, runs-of-4 data branch, a call/ret");
        $display(" result checksum:  not-taken=0x%08h   predictor=0x%08h   %s",
                 nt_res, bp_res, (nt_res===bp_res)?"(match)":"(MISMATCH!)");
        $display("");
        $display(" predict-not-taken (baseline):");
        $display("   control transfers : %0d", nt_ctrl);
        $display("   taken (=flushes)  : %0d", nt_tak);
        $display("   cycles to finish  : %0d", nt_cyc);
        $display("");
        $display(" BTB + 2-bit predictor:");
        $display("   control transfers : %0d", bp_ctrl_s);
        $display("   taken             : %0d", bp_tak_s);
        $display("   mispredictions    : %0d", bp_mis_s);
        if (bp_ctrl_s != 0)
            $display("   misprediction rate: %0d.%02d %% (%0d per 1000)",
                     (bp_mis_s*100)/bp_ctrl_s, ((bp_mis_s*10000)/bp_ctrl_s)%100,
                     (bp_mis_s*1000)/bp_ctrl_s);
        $display("   cycles to finish  : %0d", bp_cyc_s);
        $display("");
        // each flush/mispred costs 2 squashed slots; report the saving
        $display(" mispredictions:  %0d -> %0d   (%0d fewer)", nt_tak, bp_mis_s, nt_tak-bp_mis_s);
        if (bp_cyc_s != 0 && nt_cyc > bp_cyc_s)
            $display(" cycles:          %0d -> %0d   (%0d.%01dx, %0d cycles saved)",
                     nt_cyc, bp_cyc_s,
                     (nt_cyc*10)/bp_cyc_s/10, (nt_cyc*10)/bp_cyc_s%10, nt_cyc-bp_cyc_s);
        $display("=============================================================");
        if (nt_res===bp_res && nt_done && bp_done && bp_mis_s < nt_tak)
            $display("BRANCH PREDICTOR: PASS");
        else
            $display("BRANCH PREDICTOR: FAIL");
        $finish;
    end
endmodule
`default_nettype wire
