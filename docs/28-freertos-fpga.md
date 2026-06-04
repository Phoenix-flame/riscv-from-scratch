# Step 28 — FreeRTOS on the Zynq-7010 (synthesizable)

Step 27 ran FreeRTOS in simulation, but on `soc_rtos` — which is built from the
single-cycle `cpu_core` with combinational memories and the `$write`/`$finish`
simulation models. None of that synthesizes. This step puts FreeRTOS on a SoC
that is **entirely synthesizable** and can be placed into the Zynq-7010's
programmable logic, running the kernel from block RAM.

## What had to change for real hardware

The blockers are the same ones from Step 23 (the bare-metal BRAM SoC), now applied
to the RTOS:

1. **Registered-read block RAM** instead of combinational memory → use the
   multi-cycle core `cpu_mc` (it tolerates the one-cycle BRAM read latency).
2. **A real UART** (`uart_hw` → `uart_tx` serializer) instead of `$write`.
3. **A synthesizable halt** (a register that lights an LED and freezes the core)
   instead of `$finish`.
4. **The 64-bit CLINT** (`clint.v`) instead of the sim timer.

One happy fact made this clean: the FreeRTOS binary contains **zero atomic
instructions** (the RISC-V port synchronizes by disabling interrupts, not with
LR/SC/AMO). So `cpu_mc` — which implements RV32IM + Zicsr + traps but not the A
extension — runs the kernel unmodified once it's built `-march=rv32im`.

## The synthesizable SoC

`rtl/soc_rtos_fpga.v` wires it together:

```
cpu_mc  +  bram_rom (64 KB)  +  bram_ram (64 KB)  +  uart_hw  +  clint  +  halt/LED
```

A subtlety worth noting: this is a Harvard machine (separate instruction and data
buses), so `.rodata`/`.data` can't be read from the instruction ROM at run time —
they must live in the data RAM. The trick used here is to **initialize both block
RAMs from the same image word-hex**. Because `bin2hex` emits one 32-bit word per
line starting at byte 0, a data read of byte address `A` lands on word `A/4`,
which is exactly where that byte of `.rodata`/`.data` sits in the image. The data
RAM therefore holds a (harmless) copy of `.text` in its low words plus the correct
read-only/initialized data above it; `.bss`, the heap, and the stack are zero and
set up at boot by `start.S`.

`rtl/fpga_top_rtos.v` is the board top (`clk_125`, `btn_rst`, `uart_tx`, `led[0]`),
reusing `constraints/zynq7010.xdc` unchanged — same port names as the Step 23 top.

## Build and run (simulation)

```
git clone https://github.com/FreeRTOS/FreeRTOS-Kernel
make freertos-fpga FREERTOS_KERNEL=/path/to/FreeRTOS-Kernel   # rv32im image -> fr_fpga.hex
make freertos-fpga-run                                        # run on soc_rtos_fpga
```

Output (the kernel running on the synthesizable core):

```
FreeRTOS starting on RV32IMA core...
consumer got 0 ... consumer got 9
FreeRTOS demo done
[soc] halted (LED on)
```

This is the same kernel and demo as Step 27, but every module in the design is
synthesizable RTL — the UART output is a real serial bitstream, and the program
lives in inferred block RAM.

## Putting it on the board (Vivado, outside this environment)

1. New project targeting `xc7z010clg400-1`.
2. Add sources: `rtl/{alu,regfile,immgen,control,csr,uart_tx,uart_hw,clint,
   bram_rom,bram_ram,cpu_mc,soc_rtos_fpga,fpga_top_rtos}.v` and
   `constraints/zynq7010.xdc`.
3. Set `fpga_top_rtos` as top; set its `IMEM_INIT` **and** `DMEM_INIT` to
   `sw/freertos/fr_fpga.hex` (Vivado honors `$readmemh` for BRAM init during
   synthesis).
4. **For correct timing**, rebuild the image with `configCPU_CLOCK_HZ = 125000000`
   so the 1 kHz tick is accurate (the shipped `fr_fpga.hex` uses a smaller clock
   constant so it ticks quickly in simulation), and keep `CLKS_PER_BIT = 1085`
   for 115200 baud at 125 MHz.
5. Generate the bitstream, program the PL, attach a 3.3 V USB-UART to the Pmod
   `uart_tx` pin at 115200 baud, and watch FreeRTOS print. The LED lights when the
   demo halts.

## Resource sanity (XC7Z010)

Two 64 KB block RAMs ≈ 32 BRAM blocks of the device's 60 — comfortable. The
multi-cycle core plus peripherals are a few thousand LUTs of 17.6 K. As with the
earlier FPGA steps, Fmax is limited by the combinational divider and the
fetch→decode→ALU path, so drive it at a modest clock (an MMCM-divided clock is the
easy fix; set `configCPU_CLOCK_HZ`/`CLKS_PER_BIT` to match).

## Honest status

- Verified **in simulation** on the exact synthesizable RTL; the Vivado
  place-and-route and on-board run are yours to do (no FPGA tools here).
- The hardware-correct startup currently relies on preloading the data RAM with
  the image (the `$readmemh` init). That's fine for a BRAM design; a flash-based
  boot would instead copy `.data`/`.rodata` from non-volatile storage in
  `start.S`.
- Still flat machine mode — the MMU isn't used (the standard FreeRTOS port doesn't
  virtualize memory).

## Takeaway

The leap from "FreeRTOS in a simulator" to "FreeRTOS that can go in an FPGA" was
almost entirely the Step 23 lesson again — registered block-RAM reads force the
multi-cycle core and a real UART/halt — plus the realization that the kernel needs
no atomics, so the existing synthesizable core runs it as-is. The RTOS now lives
in the same fabric the CPU was built in.
