# Step 14 — From simulation to FPGA: a real UART on a Zynq-7010

> "I added `__NOP()` — now can it run on a Zynq-7010 and use UART?"

`__NOP()` is just a macro that emits a single `nop` instruction; it's software
and has no bearing on hardware deployment. But the real question — *can this run
on a Zynq-7010 and drive a real UART?* — the answer is **yes, with the right
changes**, and this step makes them and verifies the result.

## What a Zynq-7010 actually is

The XC7Z010 is a **Zynq-7000 SoC** with two halves:

- **PS (Processing System):** hard dual-core ARM Cortex-A9 CPUs, a DDR
  controller, and hardened peripherals including a **UART** — fixed silicon.
- **PL (Programmable Logic):** Artix-7-class FPGA fabric — where *your* soft
  RISC-V core lives.

So "run on Zynq" means **synthesize your Verilog into the PL**. That's a Vivado
flow (synthesis → place & route → bitstream), completely different from
`iverilog` simulation. Your core runs as real gates clocked by a real clock.

## What had to change from the simulation SoC

Three pieces of `soc.v` were *simulation models*, not hardware:

| Sim (`soc.v`) | Hardware (`fpga_top.v`) |
|---------------|--------------------------|
| `uart.v` prints with `$write` | `uart_hw.v` **serializes bits out a pin** |
| `syscon.v` calls `$finish` | a write just lights a "done" LED |
| testbench loads the program | program baked into BRAM via `$readmemh` |
| ideal clock in the TB | real `clk` + `rstn` ports + XDC pins |

New, synthesizable files:
- `rtl/uart_tx.v` — a real UART transmitter
- `rtl/uart_hw.v` — the MMIO wrapper around it
- `rtl/fpga_top.v` — the synthesizable top (replaces `soc.v`)
- `constraints/zynq.xdc` — pin/clock constraints template

### The real UART transmitter

A UART line idles high, then sends a **start bit (0)**, **8 data bits LSB-first**,
and a **stop bit (1)**. Each bit lasts `CLKS_PER_BIT = CLK_FREQ / BAUD` clock
cycles. `uart_tx.v` is a 4-state machine (IDLE → START → DATA → STOP) doing
exactly that, with a counter timing each bit. For 100 MHz and 115200 baud,
`CLKS_PER_BIT = 868`.

It's verified by sampling the line and decoding it back:

```
$ make uart_tx
ok   transmitted 0x41 -> received 0x41 ('A')
ok   transmitted 0x5A -> received 0x5a ('Z')
ALL TESTS PASSED
```

### Software must now pace itself

The sim UART accepted bytes instantly; a real one can't take a new byte until
the previous one finishes (~10 bit-periods). So `uart_putc` now **polls** the
status register before writing:

```c
void uart_putc(char c) { while (!(UART_ST & 1u)) { } UART_TX = (unsigned char)c; }
```

`uart_hw.v` reports `STATUS bit0 = !busy`. (In the sim model STATUS always reads
ready, so this same firmware still works in `make soc` — it's just a no-op
there.)

## End-to-end proof in simulation

Before touching a board, `fpga_top` is exercised with a UART **receiver model**
that samples the real `uart_tx` pin and prints what it decodes — so the text
below truly came out a serializer, bit by bit:

```
$ make fpga
---- decoded from the real uart_tx pin ----
Test 05
Hello World from my custom risc-v processor ...
formatting: dec=-42  uns=1234  hex=0x0000cafe  char=!
loop took 32 timer cycles
program signaled done (led = 0001)
```

This is the same logic the PL would run; only the clock speed and pin mapping
differ on real hardware.

## The Vivado flow (on a machine with Vivado + the board)

1. **New RTL project**, target part `xc7z010` (the exact part/package matches
   your board, e.g. `xc7z010clg400-1` for Zybo Z7-10).
2. **Add sources:** all of `rtl/*.v` *except* the simulation-only models
   (`uart.v`, `syscon.v`, `soc.v`, `cpu.v`). Use `cpu_core.v` + `fpga_top.v` +
   the peripherals. Set **`fpga_top` as the top module**.
3. **Set parameters** on `fpga_top`: `CLK_FREQ_HZ` to your PL clock, `BAUD` to
   e.g. 115200. Make sure `INIT_FILE`/`DATA_INIT` point to `socdemo.hex` /
   `socdemo_data.hex` and add those as project sources so `$readmemh` finds them
   at synthesis.
4. **Add constraints:** `constraints/zynq.xdc`, with pin LOCs copied from your
   board's master XDC (see the warning in that file — the USB-UART is usually on
   the PS, so route the PL UART to a PMOD + an external 3.3 V USB-serial
   adapter).
5. **Generate Bitstream** (synthesis → implementation → bitstream).
6. **Program** the device (Hardware Manager), open a serial terminal on the
   adapter at your baud rate, press reset — the message appears.

### Updating the program without re-synthesizing

Because the program lives in BRAM initialized from the hex, you can change it
and just regenerate the bitstream — or, faster, use Vivado's **`updatemem`** to
patch the BRAM contents of an existing bitstream from a new `.mem`, no full
re-run needed.

## Honest caveats for real silicon

- **Timing / Fmax.** The single-cycle datapath has one long combinational path
  (fetch → decode → regfile → ALU → memory → next-PC). It *will* synthesize, but
  that path sets the maximum clock. Expect a modest Fmax (tens of MHz). If
  timing fails, lower the clock or pipeline the core. For a UART demo a slow
  clock is completely fine — just keep `CLK_FREQ_HZ` honest so the baud divisor
  is right.
- **Reset.** `fpga_top` synchronizes the incoming `rstn`; make sure your board's
  button polarity matches (the template assumes active-low).
- **Memory size.** RAM/ROM map to BRAM; 4 KB each is tiny for the XC7Z010's ~2
  Mb of BRAM.
- **No multiply/divide.** Still RV32I only — `kprintf`'s `/10` uses libgcc
  software division. Fine, just not fast.

## Alternative: use the PS UART instead of a PL one

If you'd rather use the Zynq's *hardened* UART (the one wired to the USB bridge
on most boards), you'd expose your core on an **AXI** interface and talk to the
PS, letting PS software (or the PS UART via EMIO) handle serial. That's a much
bigger integration job (AXI, the Zynq processing-system IP, address mapping) and
a different tutorial. The PL soft-UART here keeps everything in your own RTL,
which is the better learning path.

## Takeaway

Going from simulation to a Zynq-7010 isn't about a `nop` macro — it's about
replacing simulation *models* with real hardware (a UART that serializes bits, a
real clock/reset, pin constraints) and running the Vivado synthesis flow. The
core, memories, decoder, and timer you built are already synthesizable; the only
genuinely new hardware needed was the UART transmitter, which is built and
verified here. Your RISC-V processor can run on the PL and print over a real
serial line.
