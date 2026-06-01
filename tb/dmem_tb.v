// =====================================================================
// dmem_tb.v  -  Self-checking testbench for data memory
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module dmem_tb;
    reg         clk;
    reg         we;
    reg  [31:0] addr, wdata;
    reg  [2:0]  funct3;
    wire [31:0] rdata;
    integer errors = 0;

    dmem #(.BYTES(1024)) dut (
        .clk(clk), .we(we), .addr(addr),
        .wdata(wdata), .funct3(funct3), .rdata(rdata)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    localparam SB=3'b000, SH=3'b001, SW=3'b010;
    localparam LB=3'b000, LH=3'b001, LW=3'b010, LBU=3'b100, LHU=3'b101;

    task store;
        input [31:0] a; input [31:0] d; input [2:0] f3;
        begin
            @(negedge clk);
            we = 1; addr = a; wdata = d; funct3 = f3;
            @(posedge clk);
            @(negedge clk); we = 0;
        end
    endtask

    task load_check;
        input [31:0] a; input [2:0] f3; input [31:0] expected;
        begin
            addr = a; funct3 = f3; #1;
            if (rdata !== expected) begin
                $display("FAIL load f3=%b @%h -> got %h, expected %h",
                         f3, a, rdata, expected);
                errors = errors + 1;
            end else
                $display("ok   load f3=%b @%h -> %h", f3, a, rdata);
        end
    endtask

    initial begin
        $dumpfile("build/dmem_tb.vcd");
        $dumpvars(0, dmem_tb);
        we = 0; addr = 0; wdata = 0; funct3 = SW;

        // Store a full word, read it back.
        store(32'h0, 32'hAABBCCDD, SW);
        load_check(32'h0, LW, 32'hAABBCCDD);

        // Little-endian byte reads of that word.
        load_check(32'h0, LBU, 32'h000000DD);  // lowest byte
        load_check(32'h1, LBU, 32'h000000CC);
        load_check(32'h3, LBU, 32'h000000AA);  // highest byte

        // Signed byte: 0xAA has bit7 set -> sign-extends to 0xFFFFFFAA.
        load_check(32'h3, LB,  32'hFFFFFFAA);

        // Half-word reads.
        load_check(32'h0, LHU, 32'h0000CCDD);
        load_check(32'h2, LHU, 32'h0000AABB);
        load_check(32'h2, LH,  32'hFFFFAABB);  // 0xAABB sign bit set

        // Store byte then half, verify they land correctly.
        store(32'h10, 32'h0000007F, SB);
        load_check(32'h10, LBU, 32'h0000007F);
        store(32'h20, 32'h00001234, SH);
        load_check(32'h20, LHU, 32'h00001234);
        load_check(32'h20, LBU, 32'h00000034);  // low byte of the half

        $display("--------------------------------------------------");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule

`default_nettype wire
