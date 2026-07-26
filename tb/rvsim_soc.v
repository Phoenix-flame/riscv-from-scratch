// =====================================================================
// rvsim_soc.v  -  generic harness for the SoC (rtl/soc.v)
// ---------------------------------------------------------------------
// Same runtime-loaded model as rvsim_cpu.v, but around the full SoC:
// the program can print over the UART and halt itself through the syscon
// device ($finish). Register file lives one level deeper, inside u_core.
//
// Plusargs: identical to rvsim_cpu.v
//   +HEX / +DATA / +CYCLES / +TRACE / +MEMSTART / +MEMWORDS / +VCD
// (+DATA here preloads the system RAM, e.g. a program's .rodata/.data.)
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

`define RVSIM_REG(i)  dut.u_core.u_regfile.regs[i]
`define RVSIM_DMEM(i) dut.u_ram.mem[i]
`define RVSIM_PC      pc
`define RVSIM_INSTR   instr

module rvsim_soc_tb;
    reg  clk, rst;
    wire [31:0] pc, instr;

    soc #(.INIT_FILE(""), .DATA_INIT("")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // ---- runtime configuration ----
    integer      rvsim_cycles;
    integer      max_cycles;
    integer      do_trace;
    integer      rvsim_memstart, rvsim_memwords;
    integer      rvsim_i, rvsim_a;        // dump-loop temporaries
    reg [31:0]   rvsim_w;
    reg [255:0]  rvsim_halt;
    reg [1023:0] hexfile, datafile, vcdfile;
    integer      ok;
    reg          self_finish;             // 1 = we stopped it; 0 = syscon did

    integer c, same, zrun;
    reg [31:0] prev_pc;
    localparam STALL_LIMIT = 4;
    localparam ZERO_LIMIT  = 8;

    initial begin
        rvsim_halt     = "cycle limit reached";
        rvsim_cycles   = 0;
        max_cycles     = 200000;
        do_trace       = 0;
        rvsim_memstart = 0;
        rvsim_memwords = 0;
        self_finish    = 0;

        if (!$value$plusargs("HEX=%s", hexfile)) begin
            $display("[rvsim] ERROR: no +HEX=<file> supplied");
            $finish;
        end
        ok = $value$plusargs("CYCLES=%d",   max_cycles);
        ok = $value$plusargs("TRACE=%d",    do_trace);
        ok = $value$plusargs("MEMSTART=%d", rvsim_memstart);
        ok = $value$plusargs("MEMWORDS=%d", rvsim_memwords);
        if ($value$plusargs("VCD=%s", vcdfile)) begin
            $dumpfile(vcdfile);
            $dumpvars(0, rvsim_soc_tb);
        end

        rst = 1;
        #1;
        $readmemh(hexfile, dut.u_core.u_imem.mem);
        if ($value$plusargs("DATA=%s", datafile))
            $readmemh(datafile, dut.u_ram.mem);

        @(posedge clk); #1; rst = 0;

        prev_pc = 32'hffff_ffff; same = 0; zrun = 0;
        for (c = 0; c < max_cycles; c = c + 1) begin
            if (do_trace)                  // pc/instr = what executes now
                $display("[trace] %0d pc=%08h instr=%08h", c, pc, instr);
            @(posedge clk); #1;
            rvsim_cycles = c + 1;

            if (pc === prev_pc) same = same + 1; else same = 0;
            prev_pc = pc;
            if (instr === 32'h0) zrun = zrun + 1; else zrun = 0;

            if (same >= STALL_LIMIT) begin
                rvsim_halt = "PC stalled (spin loop)";
                c = max_cycles;
            end else if (zrun >= ZERO_LIMIT) begin
                rvsim_halt = "ran off end (zero instructions)";
                c = max_cycles;
            end
        end
        self_finish = 1;
        $finish;
    end

    // Runs on our $finish AND on a syscon-triggered $finish.
    final begin
        `include "tb/rvsim_dump.vh"
    end
endmodule

`default_nettype wire
