// =====================================================================
// mul_2c_tb.v  -  the registered multiplier against the ALU's products
// ---------------------------------------------------------------------
// alu.v's three 64-bit products (MUL_2C = 0) are the reference; they pass
// riscv-tests rv32um. Every operand pair goes through both: mul_2c with the
// pipeline's handshake (want held until done, then go), and the ALU. The
// operands: RV32M's corners (0, 1, -1, 2^31, 2^31-1, ...) in all four
// operations, then random ones of every width. Also checked: three cycles
// each, a mid-run abort, a held result that stays put, a frozen first cycle.
// =====================================================================
module mul_2c_tb;
    reg         clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         want = 0, go = 0, start_ok = 1;
    reg  [1:0]  op = 0;
    reg  [31:0] a = 0, b = 0;
    wire        done;
    wire [31:0] result;
    mul_2c dut (.clk(clk), .rst(rst), .want(want), .start_ok(start_ok), .go(go),
                .op(op), .a(a), .b(b), .done(done), .result(result));

    // the reference: alu_op 10..13 = MUL MULH MULHSU MULHU
    wire [31:0] ref_res;
    wire        ref_zero;
    alu #(.M_EXT(1)) refalu (.a(a), .b(b), .alu_op(5'd10 + {3'd0, op}), .result(ref_res), .zero(ref_zero));

    integer errors = 0, checks = 0, cycles, seed = 58;

    task multiply(input [1:0] o, input [31:0] x, input [31:0] y);
        begin
            @(negedge clk);
            op = o; a = x; b = y; want = 1; go = 0; cycles = 0;
            while (!done) begin
                @(negedge clk); cycles = cycles + 1;
                if (cycles > 10) begin $display("FAIL: op %0d never finished", o); errors = errors + 1; $finish; end
            end
            #1 checks = checks + 1;
            if (result !== ref_res) begin
                errors = errors + 1;
                if (errors < 10) $display("FAIL: op %0d  %h * %h -> %h, want %h", o, x, y, result, ref_res);
            end
            if (cycles != 2) begin
                errors = errors + 1;
                if (errors < 10) $display("FAIL: op %0d took %0d cycles to done, want 2", o, cycles);
            end
            repeat (2) begin @(negedge clk); if (result !== ref_res || !done) begin
                errors = errors + 1; $display("FAIL: result moved while held"); end end
            go = 1; @(negedge clk); go = 0; want = 0;
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

        for (k = 0; k < 4; k = k + 1)
            for (i = 0; i < 12; i = i + 1)
                for (j = 0; j < 12; j = j + 1)
                    multiply(k[1:0], corner[i], corner[j]);

        for (i = 0; i < 4000; i = i + 1) begin
            x = $random(seed) >> ($random(seed) & 31);
            y = $random(seed) >> ($random(seed) & 31);
            if (($random(seed) & 3) == 0) x = -x;
            if (($random(seed) & 3) == 0) y = -y;
            multiply(i[1:0], x, y);
        end

        // killed after the operands are latched: want drops, the unit is idle,
        // and the next multiply is right
        @(negedge clk); op = 2'd1; a = 32'h1234_5678; b = 32'h9ABC_DEF0; want = 1;
        @(negedge clk); want = 0; repeat (2) @(negedge clk);
        if (done) begin errors = errors + 1; $display("FAIL: done after an abort"); end
        multiply(2'd2, 32'hFFFF_FF00, 32'd13);
        multiply(2'd3, 32'hFFFF_FF00, 32'hFFFF_FFFF);

        // a frozen first cycle delays the start but not the answer
        start_ok = 0; op = 2'd0; a = 32'd91; b = 32'd7; want = 1;
        repeat (4) @(negedge clk);
        if (done) begin errors = errors + 1; $display("FAIL: started while frozen"); end
        start_ok = 1;
        while (!done) @(negedge clk);
        #1 checks = checks + 1;
        if (result !== 32'd637) begin errors = errors + 1; $display("FAIL: 91*7 = %0d", result); end
        go = 1; @(negedge clk); go = 0; want = 0; @(negedge clk);

        if (errors == 0) $display("MUL-2C: ALL PASS (%0d multiplies checked against the ALU's products, 3 cycles each)", checks);
        else $display("MUL-2C: %0d FAILED", errors);
        $finish;
    end
endmodule
