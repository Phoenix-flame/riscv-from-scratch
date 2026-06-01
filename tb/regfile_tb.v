// =====================================================================
// regfile_tb.v  -  Self-checking testbench for the register file
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

module regfile_tb;

    reg         clk;
    reg         we;
    reg  [4:0]  rs1_addr, rs2_addr, rd_addr;
    reg  [31:0] rd_data;
    wire [31:0] rs1_data, rs2_data;

    integer errors = 0;

    regfile dut (
        .clk(clk), .we(we),
        .rs1_addr(rs1_addr), .rs2_addr(rs2_addr),
        .rd_addr(rd_addr), .rd_data(rd_data),
        .rs1_data(rs1_data), .rs2_data(rs2_data)
    );

    // 10 ns clock: toggle every 5 ns.
    initial clk = 0;
    always #5 clk = ~clk;

    // Drive a write so it is captured on the next rising edge.
    task write_reg;
        input [4:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk);          // set up inputs while clock is low
            we = 1'b1; rd_addr = addr; rd_data = data;
            @(posedge clk);          // value is captured here
            @(negedge clk);
            we = 1'b0;               // de-assert write enable
        end
    endtask

    // Combinational read check (no edge needed).
    task check_read1;
        input [4:0]  addr;
        input [31:0] expected;
        begin
            rs1_addr = addr;
            #1;
            if (rs1_data !== expected) begin
                $display("FAIL read x%0d -> got %h, expected %h",
                         addr, rs1_data, expected);
                errors = errors + 1;
            end else
                $display("ok   read x%0d -> %h", addr, rs1_data);
        end
    endtask

    initial begin
        $dumpfile("build/regfile_tb.vcd");
        $dumpvars(0, regfile_tb);

        we = 0; rs1_addr = 0; rs2_addr = 0; rd_addr = 0; rd_data = 0;

        // 1) Fresh registers read as 0.
        check_read1(5'd1, 32'd0);

        // 2) Write x1 = 0xDEADBEEF, read it back.
        write_reg(5'd1, 32'hDEADBEEF);
        check_read1(5'd1, 32'hDEADBEEF);

        // 3) Write x2 = 42, both registers still hold their values.
        write_reg(5'd2, 32'd42);
        check_read1(5'd1, 32'hDEADBEEF);
        check_read1(5'd2, 32'd42);

        // 4) x0 is hard-wired to zero: writing it must have no effect.
        write_reg(5'd0, 32'hFFFFFFFF);
        check_read1(5'd0, 32'd0);

        // 5) Write must be ignored when we = 0.
        @(negedge clk);
        we = 1'b0; rd_addr = 5'd3; rd_data = 32'hCAFEBABE;
        @(posedge clk); @(negedge clk);
        check_read1(5'd3, 32'd0);

        // 6) Two read ports can read different registers at once.
        rs1_addr = 5'd1; rs2_addr = 5'd2; #1;
        if (rs1_data !== 32'hDEADBEEF || rs2_data !== 32'd42) begin
            $display("FAIL dual read -> %h , %h", rs1_data, rs2_data);
            errors = errors + 1;
        end else
            $display("ok   dual read -> %h , %h", rs1_data, rs2_data);

        $display("--------------------------------------------------");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end

endmodule

`default_nettype wire
