// =====================================================================
// alu_tb.v  -  Self-checking testbench for the ALU
// ---------------------------------------------------------------------
// A testbench is non-synthesizable Verilog whose only job is to poke
// the inputs of the Device Under Test (DUT) and check its outputs.
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module alu_tb;

    // Registers drive the DUT inputs; wires read its outputs.
    reg  [31:0] a, b;
    reg  [3:0]  alu_op;
    wire [31:0] result;
    wire        zero;

    integer errors = 0;

    // ---- Instantiate the Device Under Test --------------------------
    alu dut (
        .a(a), .b(b), .alu_op(alu_op),
        .result(result), .zero(zero)
    );

    // Mirror of the opcodes so the test reads clearly.
    localparam ADD=4'b0000, SUB=4'b0001, AND=4'b0010, OR=4'b0011,
               XOR=4'b0100, SLL=4'b0101, SRL=4'b0110, SRA=4'b0111,
               SLT=4'b1000, SLTU=4'b1001;

    // A reusable checking task: apply inputs, wait, compare.
    task check;
        input [3:0]  op;
        input [31:0] ia, ib, expected;
        begin
            a = ia; b = ib; alu_op = op;
            #1;  // let the combinational logic settle
            if (result !== expected) begin
                $display("FAIL op=%b a=%h b=%h -> got %h, expected %h",
                         op, ia, ib, result, expected);
                errors = errors + 1;
            end else begin
                $display("ok   op=%b a=%h b=%h -> %h", op, ia, ib, result);
            end
        end
    endtask

    initial begin
        // Generate a waveform file for GTKWave.
        $dumpfile("build/alu_tb.vcd");
        $dumpvars(0, alu_tb);

        check(ADD,  32'd5,        32'd7,        32'd12);
        check(SUB,  32'd10,       32'd3,        32'd7);
        check(SUB,  32'd3,        32'd10,       -32'sd7); // wraps around
        check(AND,  32'hFF00FF00, 32'h0F0F0F0F, 32'h0F000F00);
        check(OR,   32'hFF00FF00, 32'h0F0F0F0F, 32'hFF0FFF0F);
        check(XOR,  32'hFFFF0000, 32'h0F0F0F0F, 32'hF0F00F0F);
        check(SLL,  32'h00000001, 32'd4,        32'h00000010);
        check(SRL,  32'h80000000, 32'd4,        32'h08000000);
        check(SRA,  32'h80000000, 32'd4,        32'hF8000000); // sign keeps
        check(SLT,  -32'sd5,      32'd3,        32'd1);        // -5 < 3
        check(SLT,  32'd5,        32'd3,        32'd0);
        check(SLTU, 32'hFFFFFFFF, 32'd1,        32'd0);        // huge !< 1
        check(SUB,  32'd42,       32'd42,       32'd0);        // zero flag

        if (zero !== 1'b1)
            begin $display("FAIL zero flag not set"); errors = errors + 1; end

        $display("--------------------------------------------------");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end

endmodule

`default_nettype wire
