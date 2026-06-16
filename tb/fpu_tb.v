`timescale 1ns/1ps
`default_nettype none
// Drives fpu_f with Python-generated golden vectors. Each vector is
// {op, a, b, expected}; the op word also carries funct3 in bits [10:8] for the
// sgnj / min-max / compare variants. Random arithmetic vectors stay in the
// normal range so flush-to-zero never diverges from the host float32 result.
// fcvt.w.s vectors (op 8) use truncation (RTZ); everything else RNE.
module fpu_tb;
    reg clk=0, rst=1; always #5 clk=~clk;

    reg  [31:0] op, a, b, exp_res;
    reg  [2:0]  fmt3, rm;
    reg         start;
    wire [31:0] result;
    wire        to_int, done, busy;
    wire [4:0]  flags;

    fpu_f dut (.clk(clk), .rst(rst), .start(start), .op(op[3:0]),
               .fmt3(fmt3), .rm(rm), .a(a), .b(b),
               .result(result), .to_int(to_int), .flags(flags),
               .done(done), .busy(busy));

    reg [31:0] vmem [0:2047];
    reg [1023:0] vfile;
    integer nvec, i, fails, g;
    reg [31:0] go, ga, gb, ge;

    initial begin
        if (!$value$plusargs("VEC=%s", vfile)) vfile = "tb/fpu_vectors.hex";
        $readmemh(vfile, vmem);
        nvec = 0;
        for (i = 0; i < 512; i = i + 1)
            if (vmem[4*i] !== 32'hxxxxxxxx) nvec = i + 1;

        start = 0; fails = 0;
        repeat(3) @(posedge clk); #1; rst = 0;

        for (i = 0; i < nvec; i = i + 1) begin
            go = vmem[4*i]; ga = vmem[4*i+1]; gb = vmem[4*i+2]; ge = vmem[4*i+3];
            rm   = (go[3:0] == 8) ? 3'b001 : 3'b000;
            fmt3 = go[10:8];
            op = {28'd0, go[3:0]}; a = ga; b = gb;
            @(negedge clk); start = 1; @(negedge clk); start = 0;
            g = 0; while (!done && g < 200) begin @(posedge clk); g = g + 1; end
            #1;
            if (result !== ge) begin
                fails = fails + 1;
                if (fails <= 20)
                    $display("FAIL op=%0d f3=%0d a=%h b=%h got=%h exp=%h",
                             go[3:0], go[10:8], ga, gb, result, ge);
            end
            @(negedge clk);
        end

        $display("");
        $display("FPU vectors [%0s]: %0d total, %0d mismatches", vfile, nvec, fails);
        if (fails == 0) $display("FPU-UNIT: ALL PASS");
        else            $display("FPU-UNIT: FAIL");
        $finish;
    end
endmodule
`default_nettype wire
