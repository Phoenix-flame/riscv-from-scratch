// =====================================================================
// rvsim_cpu.v  -  generic harness for the single-cycle core (rtl/cpu.v)
// ---------------------------------------------------------------------
// A program is loaded at run time from a $readmemh word-hex file given
// on the vvp command line, so ONE compiled simulation runs any number of
// programs. Driven by tools/rvsim.
//
// Plusargs:
//   +HEX=<file>     program image, one 32-bit word per line   (required)
//   +DATA=<file>    optional preload of data memory (byte-hex)
//   +CYCLES=<n>     max cycles to run before stopping   (default 200000)
//   +TRACE=1        print pc/instr every retired cycle
//   +MEMSTART=<n>   first byte address of the data-memory window to dump
//   +MEMWORDS=<n>   number of 32-bit words to dump from there
//   +VCD=<file>     also write a VCD waveform to <file>
// =====================================================================
`timescale 1ns/1ps
`default_nettype none

`define RVSIM_REG(i)  dut.u_regfile.regs[i]
`define RVSIM_DMEM(i) dut.u_dmem.mem[i]
`define RVSIM_PC      pc
`define RVSIM_INSTR   instr

module rvsim_cpu_tb;
    reg  clk, rst;
    wire [31:0] pc, instr;

    cpu #(.INIT_FILE("")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr)
    );

    initial clk = 0;
    always #5 clk = ~clk;                  // 10 ns period

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
    reg          self_finish;

    integer c, same, zrun;
    reg [31:0] prev_pc;
    localparam STALL_LIMIT = 4;            // same PC N cycles -> spin loop
    localparam ZERO_LIMIT  = 8;            // N zero fetches   -> ran off end

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
            $dumpvars(0, rvsim_cpu_tb);
        end

        rst = 1;
        #1;                                // let RTL init-clear loops settle
        $readmemh(hexfile, dut.u_imem.mem);
        if ($value$plusargs("DATA=%s", datafile))
            $readmemh(datafile, dut.u_dmem.mem);

        @(posedge clk); #1; rst = 0;       // one reset cycle, then release

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
                c = max_cycles;            // break
            end else if (zrun >= ZERO_LIMIT) begin
                rvsim_halt = "ran off end (zero instructions)";
                c = max_cycles;            // break
            end
        end
        self_finish = 1;
        $finish;
    end

    // Always dump final state, however the run ended.
    final begin
        `include "tb/rvsim_dump.vh"
    end
endmodule

`default_nettype wire
