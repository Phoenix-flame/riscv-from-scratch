// =====================================================================
// rvtest_harness.vh  -  shared body of the riscv-tests harnesses
// ---------------------------------------------------------------------
// The official suite is ~70 separate programs per core, so the harness
// takes its program on the vvp command line: ONE compiled simulation
// runs every test. Driven by tools/rvtests.
//
// Plusargs:
//   +ROM=<file>     instruction image, one 32-bit word per line (required)
//   +RAM=<file>     data image (optional; format depends on the harness)
//   +CYCLES=<n>     cycle cap before declaring a hang (default 2000000)
//   +TRACE=1        print pc/instr every cycle
//
// A test reports its verdict by storing to `tohost`, which link.ld puts
// at the SYSCON address 0x2000_0000 -- so the harness just watches the
// core's data bus for a store into that region and decodes the word:
//
//   1                    -> PASS
//   (testnum << 1) | 1   -> FAIL in sub-test `testnum`
//   testnum | 1337       -> an unexpected trap reached other_exception
//
// The verdict line is machine-readable; tools/rvtests parses it.
//
// Before including this file the harness must provide:
//   clk, rst                       -- the clock it drives and the reset
//   rvt_pc                         -- [31:0] the current PC (for tracing)
//   rvt_instr                      -- [31:0] the current instruction
//   rvt_wr / rvt_waddr / rvt_wdata -- a store committing this cycle
//   task rvt_load(rom, ram, has_ram) -- $readmemh into its own memories
// =====================================================================

    reg [1023:0] rvt_rom_file, rvt_ram_file;
    integer      rvt_max_cycles, rvt_cycles, rvt_ok, rvt_trace;
    reg          rvt_has_ram, rvt_done;

    initial begin
        rvt_cycles     = 0;
        rvt_max_cycles = 2000000;
        rvt_trace      = 0;
        rvt_done       = 1'b0;

        if (!$value$plusargs("ROM=%s", rvt_rom_file)) begin
            $display("RVTEST verdict=error detail=no-rom-image");
            $finish;
        end
        rvt_ok      = $value$plusargs("CYCLES=%d", rvt_max_cycles);
        rvt_ok      = $value$plusargs("TRACE=%d",  rvt_trace);
        rvt_has_ram = $value$plusargs("RAM=%s", rvt_ram_file);

        rst = 1'b1;
        #1;                          // let the memories' init-clear loops run
        rvt_load(rvt_rom_file, rvt_ram_file, rvt_has_ram);

        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
    end

    // ---- cycle counter + optional trace ------------------------------
    always @(posedge clk) if (!rst && !rvt_done) begin
        rvt_cycles = rvt_cycles + 1;
        if (rvt_trace)
            $display("[trace] %0d pc=%08h instr=%08h", rvt_cycles, rvt_pc, rvt_instr);
    end

    // ---- the verdict: a store anywhere in the SYSCON window ----------
    always @(posedge clk) begin
        if (!rst && !rvt_done && rvt_wr && rvt_waddr[31:28] == 4'h2) begin
            rvt_done = 1'b1;
            if (rvt_wdata == 32'd1)
                $display("RVTEST verdict=pass tohost=%08h cycles=%0d",
                         rvt_wdata, rvt_cycles);
            else if ((rvt_wdata & 32'd1337) == 32'd1337)
                $display("RVTEST verdict=trap tohost=%08h cycles=%0d testnum=%0d",
                         rvt_wdata, rvt_cycles, rvt_wdata & ~32'd1337);
            else
                $display("RVTEST verdict=fail tohost=%08h cycles=%0d testnum=%0d",
                         rvt_wdata, rvt_cycles, rvt_wdata >> 1);
            $finish;
        end
    end

    // ---- hang detection ----------------------------------------------
    always @(posedge clk) begin
        if (!rst && !rvt_done && rvt_cycles >= rvt_max_cycles) begin
            rvt_done = 1'b1;
            $display("RVTEST verdict=timeout cycles=%0d pc=%08h",
                     rvt_cycles, rvt_pc);
            $finish;
        end
    end
