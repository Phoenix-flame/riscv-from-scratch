// =====================================================================
// rvsim_dump.vh  -  shared architectural-state dump for the rvsim CLI
// ---------------------------------------------------------------------
// This is a bare block of PROCEDURAL STATEMENTS (no task -- Icarus will
// not let a `final` block call one), meant to be `include`-d directly
// inside the harness's `final` block.
//
// Before including, the harness must define these macros (hierarchical
// paths into whichever DUT it instantiated):
//   `RVSIM_REG(i)   -> GPR i        (reg [31:0])
//   `RVSIM_DMEM(i)  -> data byte i  (reg [7:0])
//   `RVSIM_PC       -> current PC
//   `RVSIM_INSTR    -> current instruction word
//
// and declare these module-level variables:
//   integer     rvsim_cycles, rvsim_memstart, rvsim_memwords;
//   integer     rvsim_i, rvsim_a;
//   reg [31:0]  rvsim_w;
//   reg [255:0] rvsim_halt;
//   reg         self_finish;   // 0 => stopped by an external $finish (syscon)
//
// The dump is bracketed by two marker lines so the Python front-end can
// lift it out of the console stream; anything printed outside the block
// (UART bytes, trace lines) is the program's own output.
// =====================================================================
if (!self_finish) rvsim_halt = "halted via syscon device";
$display("===RVSIM-STATE-BEGIN===");
$display("CYCLES %0d", rvsim_cycles);
$display("PC %08h", `RVSIM_PC);
$display("INSTR %08h", `RVSIM_INSTR);
$display("HALT %0s", rvsim_halt);
for (rvsim_i = 0; rvsim_i < 32; rvsim_i = rvsim_i + 1)
    $display("REG %0d %08h", rvsim_i, `RVSIM_REG(rvsim_i));
if (rvsim_memwords > 0) begin
    for (rvsim_i = 0; rvsim_i < rvsim_memwords; rvsim_i = rvsim_i + 1) begin
        rvsim_a = rvsim_memstart + rvsim_i * 4;
        rvsim_w = { `RVSIM_DMEM(rvsim_a+3), `RVSIM_DMEM(rvsim_a+2),
                    `RVSIM_DMEM(rvsim_a+1), `RVSIM_DMEM(rvsim_a) };
        $display("DMEM %08h %08h", rvsim_a[31:0], rvsim_w);
    end
end
$display("===RVSIM-STATE-END===");
