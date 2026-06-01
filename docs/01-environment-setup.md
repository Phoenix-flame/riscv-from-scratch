# Step 01 — Environment setup on Ubuntu 24.04

We need three tools:

- **Icarus Verilog (`iverilog` + `vvp`)** — compiles and simulates Verilog.
- **GTKWave (`gtkwave`)** — views the `.vcd` waveform files the simulation
  produces.
- **A RISC-V assembler** — to turn our assembly programs into machine code.
  We'll set this up in Step 08; you don't need it yet.

## Install Icarus Verilog and GTKWave

```bash
sudo apt-get update
sudo apt-get install -y iverilog gtkwave
```

On Ubuntu 24.04 this installs Icarus Verilog 12.0, which supports the
SystemVerilog-2012 features we occasionally lean on.

## Verify the install

```bash
iverilog -V | head -1     # should print: Icarus Verilog version 12.0 ...
vvp -V    | head -1        # the runtime engine
gtkwave --version 2>&1 | head -1
```

If `gtkwave --version` complains, that's fine — it's a GUI app and may want a
display. We only need it to open files interactively.

## The build flow you'll use every step

Icarus Verilog works in two stages, like a C compiler and a program:

1. **Compile** your RTL + testbench into a simulation binary (`.vvp`):
   ```bash
   iverilog -g2012 -Wall -o build/alu_tb.vvp rtl/alu.v tb/alu_tb.v
   ```
   - `-g2012` selects the Verilog-2005 + SystemVerilog-2012 language level.
   - `-Wall` turns on warnings — read them; they catch real mistakes.
   - `-o` names the output. List every source file the testbench needs.

2. **Run** the simulation:
   ```bash
   vvp build/alu_tb.vvp
   ```
   This prints whatever your testbench `$display`s and writes a `.vcd` file.

3. **View** the waveform:
   ```bash
   gtkwave build/alu_tb.vcd
   ```

## A tiny "hello world" to prove it works

Create `tb/hello_tb.v`:

```verilog
`timescale 1ns/1ps
module hello_tb;
    initial begin
        $display("Hello from Icarus Verilog!");
        #5 $display("5 ns later...");
        $finish;
    end
endmodule
```

Compile and run:

```bash
iverilog -g2012 -o build/hello.vvp tb/hello_tb.v
vvp build/hello.vvp
```

Expected output:

```
Hello from Icarus Verilog!
5 ns later...
```

If you see that, your environment is ready.

## A note on `make` (optional convenience)

Typing the `iverilog`/`vvp` commands gets repetitive. Later you can drop a
`Makefile` in the project root so `make alu` builds and runs a test. We'll
introduce one when the number of files grows; for now, run the commands by
hand so you see exactly what's happening.

## Next

`docs/02-verilog-crash-course.md` — a focused Verilog refresher using the ALU
we are about to study, so the syntax lands on real hardware instead of toy
examples.
