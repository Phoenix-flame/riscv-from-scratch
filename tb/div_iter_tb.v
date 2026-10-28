// =====================================================================
// div_iter_tb.v  -  the iterative divider against the array divider
// ---------------------------------------------------------------------
// alu.v's / and % are the reference (and already pass riscv-tests rv32um).
// Every operand pair goes through both: the iterative unit with the
// pipeline's handshake (want held until done, then go), and the ALU with
// DIV_ITER = 0. Operands: the corners of RV32M (0, 1, -1, 2^31, 2^31-1,
// divide by zero, the signed overflow), then random ones of every width.
// Also checked: the cycle count (32 + start + done), that dropping `want`
// mid-run aborts cleanly and the next division is right, and that holding
// `go` low keeps the result stable.
// =====================================================================
module div_iter_tb;
    reg         clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         want = 0, go = 0, start_ok = 1;
    reg  [1:0]  op = 0;
    reg  [31:0] a = 0, b = 0;
    wire        done;
    wire [31:0] result;
    div_iter dut (.clk(clk), .rst(rst), .want(want), .start_ok(start_ok), .go(go),
                  .op(op), .a(a), .b(b), .done(done), .result(result));

    // the reference: the ALU with the array dividers, alu_op 14..17 = DIV DIVU REM REMU
    reg  [4:0]  ref_op = 5'd14;
    wire [31:0] ref_res;
    wire        ref_zero;
    alu #(.M_EXT(1), .DIV_ITER(0)) refalu (.a(a), .b(b), .alu_op(ref_op), .result(ref_res), .zero(ref_zero));

    integer errors = 0, checks = 0, cycles, seed = 57;

    // one division through the handshake; returns the cycles from want to done
    task divide(input [1:0] o, input [31:0] x, input [31:0] y);
        begin
            @(negedge clk);
            op = o; a = x; b = y; ref_op = 5'd14 + (o == 2'd0 ? 5'd0 : o == 2'd1 ? 5'd1 : o == 2'd2 ? 5'd2 : 5'd3);
            want = 1; go = 0; cycles = 0;
            while (!done) begin @(negedge clk); cycles = cycles + 1; if (cycles > 100) begin
                $display("FAIL: op %0d %h %h never finished", o, x, y); errors = errors + 1; $finish; end end
            #1;
            checks = checks + 1;
            if (result !== ref_res) begin
                errors = errors + 1;
                if (errors < 10) $display("FAIL: op %0d  %h , %h  -> %h, want %h", o, x, y, result, ref_res);
            end
            if (cycles != 33) begin
                errors = errors + 1;
                if (errors < 10) $display("FAIL: op %0d took %0d cycles, want 33", o, cycles);
            end
            // the pipeline holds: no go for a few cycles, the result must not move
            repeat (3) begin @(negedge clk); if (result !== ref_res || !done) begin
                errors = errors + 1; $display("FAIL: result moved while held"); end end
            go = 1; @(negedge clk); go = 0; want = 0;      // the instruction leaves EX
            @(negedge clk);
        end
    endtask

    reg [31:0] corner [0:11];
    integer i, j, k;
    reg [31:0] x, y;

    initial begin
        corner[0] = 32'h0000_0000; corner[1] = 32'h0000_0001; corner[2] = 32'hFFFF_FFFF;
        corner[3] = 32'h8000_0000; corner[4] = 32'h7FFF_FFFF; corner[5] = 32'h8000_0001;
        corner[6] = 32'h0000_0002; corner[7] = 32'hFFFF_FFFE; corner[8] = 32'h0001_0000;
        corner[9] = 32'h0000_FFFF; corner[10] = 32'hDEAD_BEEF; corner[11] = 32'h0000_0007;
        repeat (3) @(negedge clk);
        rst = 0;
        @(negedge clk);

        // corners x corners x all four ops
        for (k = 0; k < 4; k = k + 1)
            for (i = 0; i < 12; i = i + 1)
                for (j = 0; j < 12; j = j + 1)
                    divide(k[1:0], corner[i], corner[j]);

        // random: operands of random width, so small divisors and large quotients both occur
        for (i = 0; i < 4000; i = i + 1) begin
            x = $random(seed) >> ($random(seed) & 31);
            y = $random(seed) >> ($random(seed) & 31);
            if (($random(seed) & 7) == 0) x = -x;
            if (($random(seed) & 7) == 0) y = -y;
            divide(i[1:0], x, y);
        end

        // killed mid-run: want drops after 10 cycles, then an ordinary division is still right
        @(negedge clk); op = 2'd1; a = 32'd1000000; b = 32'd7; want = 1;
        repeat (10) @(negedge clk);
        want = 0; repeat (2) @(negedge clk);
        if (done) begin errors = errors + 1; $display("FAIL: done after an abort"); end
        divide(2'd0, 32'hFFFF_FF00, 32'd13);
        divide(2'd3, 32'hFFFF_FF00, 32'd13);

        // a frozen first cycle (start_ok low) delays the start but not the answer
        start_ok = 0; op = 2'd0; a = 32'd91; b = 32'd7; ref_op = 5'd14; want = 1;
        repeat (5) @(negedge clk);
        if (done) begin errors = errors + 1; $display("FAIL: started while frozen"); end
        start_ok = 1;
        while (!done) @(negedge clk);
        #1 checks = checks + 1;
        if (result !== 32'd13) begin errors = errors + 1; $display("FAIL: 91/7 = %0d", result); end
        go = 1; @(negedge clk); go = 0; want = 0; @(negedge clk);

        if (errors == 0) $display("DIV-ITER: ALL PASS (%0d divisions checked against the array divider, 33 cycles each)", checks);
        else $display("DIV-ITER: %0d FAILED", errors);
        $finish;
    end
endmodule
