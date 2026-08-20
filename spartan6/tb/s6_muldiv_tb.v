// =====================================================================
// s6_muldiv_tb.v  -  the mul/div unit against Verilog's own arithmetic
// ---------------------------------------------------------------------
// riscv-tests covers the eight RV32M instructions, but its vectors are
// hand-picked. This is the complementary check: a few thousand random
// operand pairs plus every corner case the spec calls out, compared to
// what the simulator computes with $signed/$unsigned.
//
// Both configurations are checked -- MUL_DSP=0 (sequential shift-add)
// and MUL_DSP=1 (a single 33x33 product for XST to map onto DSP48A1s) --
// because they are genuinely different multipliers.
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module s6_muldiv_tb;
    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    reg         start = 1'b0;
    reg  [2:0]  op    = 3'd0;
    reg  [31:0] a = 32'd0, b = 32'd0;
    wire        busy0, done0, busy1, done1;
    wire [31:0] res0, res1;

    s6_muldiv #(.MUL_DSP(0)) u_seq (
        .clk(clk), .rst(rst), .start(start), .op(op), .a(a), .b(b),
        .busy(busy0), .done(done0), .result(res0));

    s6_muldiv #(.MUL_DSP(1)) u_dsp (
        .clk(clk), .rst(rst), .start(start), .op(op), .a(a), .b(b),
        .busy(busy1), .done(done1), .result(res1));

    integer errors = 0, checks = 0;

    // ---- the reference model -------------------------------------------
    // Careful with signedness: in Verilog an expression is unsigned if ANY
    // of its operands is, so `cond ? unsigned_thing : $signed(a)/$signed(b)`
    // silently performs an UNSIGNED divide. Everything below is therefore
    // computed into an explicitly signed temporary first, never inside a
    // mixed-sign conditional.
    function [31:0] expected;
        input [2:0]  o;
        input [31:0] x, y;
        reg signed [31:0] sa, sb, sq, sr;
        reg        [31:0] uq, ur;
        reg signed [63:0] ex, ey, eyu, p_ss, p_su;
        reg        [63:0] p_uu;
        reg               ovf;
        begin
            sa  = x;
            sb  = y;
            ex  = $signed({{32{x[31]}}, x});
            ey  = $signed({{32{y[31]}}, y});
            eyu = $signed({32'd0, y});
            p_ss = ex * ey;
            p_su = ex * eyu;
            p_uu = {32'd0, x} * {32'd0, y};
            ovf  = (x == 32'h80000000) && (y == 32'hFFFFFFFF);

            if (y == 32'd0)      begin sq = -1;             sr = sa;      end
            else if (ovf)        begin sq = sa;             sr = 32'sd0;  end
            else                 begin sq = sa / sb;        sr = sa % sb; end

            if (y == 32'd0)      begin uq = 32'hFFFFFFFF;   ur = x;       end
            else                 begin uq = x / y;          ur = x % y;   end

            case (o)
                3'd0:    expected = p_uu[31:0];      // mul   (sign-agnostic)
                3'd1:    expected = p_ss[63:32];     // mulh
                3'd2:    expected = p_su[63:32];     // mulhsu
                3'd3:    expected = p_uu[63:32];     // mulhu
                3'd4:    expected = sq;              // div
                3'd5:    expected = uq;              // divu
                3'd6:    expected = sr;              // rem
                default: expected = ur;              // remu
            endcase
        end
    endfunction

    task run_one;
        input [2:0]  o;
        input [31:0] x, y;
        reg   [31:0] want;
        begin
            @(negedge clk);
            op = o; a = x; b = y; start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            while (!done0) @(negedge clk);
            want   = expected(o, x, y);
            checks = checks + 1;
            if (res0 !== want) begin
                errors = errors + 1;
                $display("FAIL seq op=%0d a=%08h b=%08h got=%08h want=%08h",
                         o, x, y, res0, want);
            end
            if (res1 !== want) begin
                errors = errors + 1;
                $display("FAIL dsp op=%0d a=%08h b=%08h got=%08h want=%08h",
                         o, x, y, res1, want);
            end
            // (the DSP unit finishes first on multiplies and then idles,
            //  holding its result, so comparing both here is still valid)
        end
    endtask

    integer i, k;
    reg [31:0] corners [0:9];

    initial begin
        corners[0] = 32'h00000000; corners[1] = 32'h00000001;
        corners[2] = 32'hFFFFFFFF; corners[3] = 32'h80000000;
        corners[4] = 32'h7FFFFFFF; corners[5] = 32'h0000FFFF;
        corners[6] = 32'hFFFF0000; corners[7] = 32'hDEADBEEF;
        corners[8] = 32'h00000002; corners[9] = 32'hAAAAAAAA;

        repeat (4) @(posedge clk);
        #1 rst = 1'b0;

        // every corner x every corner, for all eight operations
        for (k = 0; k < 8; k = k + 1)
            for (i = 0; i < 100; i = i + 1)
                run_one(k[2:0], corners[i / 10], corners[i % 10]);

        // random vectors
        for (i = 0; i < 1200; i = i + 1)
            run_one($random & 3'h7, $random, $random);

        // ... and a run with lots of small divisors, where the restoring
        // loop's early iterations do the most work
        for (i = 0; i < 200; i = i + 1)
            run_one(3'd4 + (i % 4), $random, {28'd0, i[3:0]});

        if (errors == 0)
            $display("s6_muldiv_tb: PASS (%0d checks)", checks);
        else
            $display("s6_muldiv_tb: FAIL (%0d errors in %0d checks)", errors, checks);
        $finish;
    end

    initial begin
        #20000000;
        $display("s6_muldiv_tb: TIMEOUT");
        $finish;
    end
endmodule

`default_nettype wire
