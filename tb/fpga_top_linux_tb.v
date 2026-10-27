`timescale 1ns/1ps
`default_nettype none
// =====================================================================
// fpga_top_linux_tb.v  -  the Linux board top, through its pins (Step 54)
// ---------------------------------------------------------------------
// fpga_top_linux with OpenZynq's ps7_gp0 and tb/ps7_hp0_model.v standing
// in for the PS: the RISC-V's RAM is the model's DDR, over S_AXI_HP0. The
// bench is the USB-serial adapter on JM1, at 115200 baud from 50 MHz (432
// clocks a bit). At each "boot> " it sends the next chunk of the stream
// (4-byte length + bytes, as tools/rvboot writes it): a corrupted image,
// then libc_demo, which runs from DDR and powers the machine off.
//
// It passes ("PASS:", as OpenZynq's `make sim` and rvgen look for) when:
//   * the core stayed in reset until the PS wrote run over GP0;
//   * the ROM rejected the bad image and libc_demo printed its result;
//   * the machine powered off with exit code 0;
//   * the PS read "RVFS" over GP0;
//   * HP0 carried reads and writes, with no AXI protocol error or misuse.
// Paths default to OpenZynq's layout (vvp runs in build/riscv_linux);
// +ROM= and +STREAM= override them.
// =====================================================================
module fpga_top_linux_tb;
    localparam CPB = 16 * 27;
    reg clk = 1'b0;
    always #10 clk = ~clk;                          // 50 MHz

    reg  rx = 1'b1;
    wire tx, led, led2;
    fpga_top_linux #(.BOOTROM_INIT("")) dut (
        .clk(clk), .resetn(1'b1), .uart_rx(rx), .uart_tx(tx), .led(led), .led2(led2));

    reg [8*256-1:0] romf, streamf;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ---- the core must wait for the PS ----
    integer early = 0;
    always @(posedge clk)
        if (dut.u_ps7.ps7_i.gp0_run !== 1'b1 && dut.rst !== 1'b1) early = early + 1;

    // ---- receive ----
    reg [8*16-1:0] last = 0;                        // the last 16 characters
    reg saw_reject = 1'b0, saw_result = 1'b0;
    integer prompts = 0, nrx = 0, i;
    reg [7:0] ch;
    initial forever begin
        @(negedge tx);
        repeat (CPB / 2) @(posedge clk);
        if (tx == 1'b0) begin
            for (i = 0; i < 8; i = i + 1) begin repeat (CPB) @(posedge clk); ch[i] = tx; end
            repeat (CPB) @(posedge clk);
            if (ch != 8'h0d) $write("%c", ch);
            nrx = nrx + 1;
            last = {last[8*15-1:0], ch};
            if (last[8*6-1:0] == "boot> ") prompts = prompts + 1;
            if (last[8*10-1:0] == "image says") saw_reject = 1'b1;
            if (last[8*15-1:0] == "squares sum=140") saw_result = 1'b1;
        end
    end

    // ---- send ----
    task send_byte; input [7:0] b; integer k; begin
        rx = 1'b0; repeat (CPB) @(posedge clk);
        for (k = 0; k < 8; k = k + 1) begin rx = b[k]; repeat (CPB) @(posedge clk); end
        rx = 1'b1; repeat (CPB) @(posedge clk);
    end endtask

    integer sfd, len, n, c, chunk = 0;
    initial begin
        if (!$value$plusargs("ROM=%s", romf)) romf = "../../projects/riscv_linux/fw/rom.hex";
        if (!$value$plusargs("STREAM=%s", streamf)) streamf = "../../projects/riscv_linux/sim/stream.bin";
        $readmemh(romf, dut.u_soc.rom);
        sfd = $fopen(streamf, "rb");
        if (sfd == 0) begin $display("FAIL: cannot open %0s", streamf); $finish; end
        c = $fgetc(sfd);
        while (c != -1) begin
            len = c | ($fgetc(sfd) << 8) | ($fgetc(sfd) << 16) | ($fgetc(sfd) << 24);
            while (prompts <= chunk) @(posedge clk);
            repeat (4 * CPB) @(posedge clk);
            for (n = 0; n < len; n = n + 1) send_byte($fgetc(sfd));
            chunk = chunk + 1;
            c = $fgetc(sfd);
        end
        $fclose(sfd);
    end

    // ---- finish ----
    integer fails = 0, maxcyc = 40000000;
    initial begin
        if ($value$plusargs("MAXCYC=%d", maxcyc)) ;
        while (dut.halted !== 1'b1 && cyc < maxcyc) @(posedge clk);
        repeat (4 * CPB) @(posedge clk);
        $display("");
        $display("board: %0s after %0d cycles, exit code %0d, %0d chunks sent, %0d bytes received",
                 dut.halted ? "powered off" : "TIMEOUT", cyc, dut.u_soc.exit_code, chunk, nrx);
        $display("board: HP0 %0d reads + %0d writes, protocol errors %0d, misuse %0d; core ran early %0d cycles",
                 dut.u_ps7.ps7_i.u_ddr.reads, dut.u_ps7.ps7_i.u_ddr.writes, dut.u_ps7.ps7_i.u_ddr.errors,
                 dut.u_ps7.ps7_i.hp0_misuse, early);
        $display("board: GP0 read at 0x40000000 -> 0x%08x", dut.u_ps7.ps7_i.gp0_id);
        if (dut.halted !== 1'b1 || dut.u_soc.exit_code != 0) fails = fails + 1;
        if (chunk != 2) fails = fails + 1;
        if (!saw_reject)                 begin $display("board: no CRC rejection"); fails = fails + 1; end
        if (!saw_result)                 begin $display("board: no libc_demo result"); fails = fails + 1; end
        if (dut.u_ps7.ps7_i.u_ddr.reads == 0 || dut.u_ps7.ps7_i.u_ddr.writes == 0) fails = fails + 1;
        if (dut.u_ps7.ps7_i.u_ddr.errors != 0 || dut.u_ps7.ps7_i.hp0_misuse != 0 || early != 0) fails = fails + 1;
        if (dut.u_ps7.ps7_i.gp0_id != 32'h5256_4653) fails = fails + 1;
        if (fails == 0) $display("PASS: the board top boots over HP0");
        else            $display("FAIL: %0d checks", fails);
        $finish;
    end
endmodule
`default_nettype wire
