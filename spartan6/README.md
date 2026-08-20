# A tiny RISC-V SoC for the Spartan-6 LX9

A self-contained RV32 system sized for an **XC6SLX9** — specifically the
[Posedge One](constraints/posedge_one_lx9.ucf) board (XC6SLX9-TQG144, 24 MHz
oscillator, FT2232 USB-serial, IS61WV5128BLL 512 KB SRAM).

The brief was "as many features as will fit". So the core is deliberately
**multi-cycle** — one shared ALU, one shared add/sub in the mul/div unit, a
distributed-RAM register file, a state machine instead of pipeline registers
and forwarding. Spending the LUTs on architecture rather than throughput is
what leaves room for M, A, C, user mode and a real trap unit on a part this
small.

Everything here is independent of the parent tutorial's `rtl/`; the only
shared file is the RVC expander, copied in so this folder stands alone.

## What the core implements

| | |
|---|---|
| **RV32I** | the base integer ISA |
| **M** | mul/mulh/mulhsu/mulhu, div/divu/rem/remu — sequential, or one-cycle multiply on DSP48A1 with `MUL_DSP=1` |
| **A** | `lr.w`/`sc.w` plus all nine AMOs, single-hart reservation |
| **C** | 16-bit instructions, including 32-bit instructions straddling two memory words |
| **Zicsr** | the machine CSR file |
| **Zicntr** | 64-bit `mcycle` / `minstret`, and `time` wired to the CLINT's real-time counter |
| **M + U** | two privilege levels, `mstatus`/`mepc`/`mcause`/`mtval`/`mscratch`, `mret` |
| **Traps** | illegal instruction, `ecall`, `ebreak`, misaligned load/store, misaligned jump target, and the three machine interrupts — `mtvec` in both direct and vectored mode |
| **`wfi`** | a real sleep state: the FSM parks until an enabled interrupt arrives |

`misa` reports what is actually built, and every extension is a parameter, so
the same file also builds a bare RV32I core when the LUTs run out.

### Cycle costs (`FAST_FETCH=1`, block RAM)

| Operation | Cycles |
|---|---|
| ALU, branch (taken or not), jump | 1 |
| store | 1 |
| load | 2 |
| AMO / `lr` / `sc` | 3 |
| mul, div, rem | ~35 (mul ~3 with `MUL_DSP=1`) |
| 32-bit instruction at an odd halfword | +1 |
| any access to the external SRAM | ~20+ |

`FAST_FETCH=1` presents the next instruction's address during the cycle that
finishes the current one. Setting it to `0` inserts a separate FETCH state —
one more cycle per instruction, but the next-PC mux drops out of the block RAM
address path. Both configurations are verified (see below).

## The SoC

```
0x0000_0000  RAM     unified code+data block RAM (MEM_WORDS x 32, default 16 KB)
0x1000_0000  UART    FIFOs, fractional baud, interrupts
0x1001_0000  CLINT   msip / mtimecmp / mtime, standard offsets
0x1002_0000  GPIO    8 out, 8 in, change interrupts
0x2000_0000  SYSCON  halt + a read-only description of the hardware
0x4000_0000  SRAM    512 KB IS61WV5128BLL (data only, not fetchable)
```

Instruction fetch and data access are the two ports of **one true dual-port
block RAM**, so there is a single flat address space and no bus arbitration.
That is also what makes a bootloader possible: a program running out of the
block RAM can write a new program into it and jump there.

`SYSCON` reports the clock frequency, the RAM size and the SRAM size, so
firmware computes its own baud divisor instead of hard-coding one. Re-synthesise
at a different PLL setting and the UART still comes up at the right rate.

### The UART

16-deep TX and RX FIFOs; 5–8 data bits; none/even/odd parity; 1–2 stop bits;
16× oversampling with a 3-sample majority vote per bit and start-bit
revalidation; overrun/framing/parity flags; an receive-to-idle event;
loopback for self-test; optional RTS/CTS; six maskable interrupt sources with
programmable FIFO watermarks.

The baud generator is a phase accumulator rather than a prescaler: add 16 each
clock, emit a tick and subtract when it reaches clocks-per-bit. The tick rate is
then exactly `16 × f_clk / clocks_per_bit` with no rounding drift, which matters
on a board whose oscillator is 24 MHz. Programming it is one divide:

```c
UART_BAUD = SYS_CLK_HZ / 115200;
```

Full register maps are in the header comment of each RTL file
([`s6_uart.v`](rtl/s6_uart.v), [`s6_clint.v`](rtl/s6_clint.v),
[`s6_gpio.v`](rtl/s6_gpio.v), [`s6_sram.v`](rtl/s6_sram.v)).

## Layout

```
spartan6/
├── rtl/            the core, the peripherals, the SoC, the FPGA top
├── tb/             self-checking testbenches (Icarus Verilog)
├── sw/             crt0, linker scripts, BSP, hello/self-test, bootloader
├── syn/            ISE 14.7 command-line flow (xst/ngdbuild/map/par/bitgen)
├── tools/          s6load.py — upload firmware over the serial port
├── constraints/    posedge_one_lx9.ucf
└── docs/           programming.md — getting a bitstream onto the board
```

## Quick start

Simulate everything (needs `iverilog` and `riscv64-unknown-elf-gcc`):

```bash
make test
```

Run the official RISC-V instruction tests against this core:

```bash
make riscv-tests
```

Build a bitstream (needs ISE 14.7 on `$PATH`):

```bash
make bit
```

Program it, then talk to the board:

```bash
make prog
make term
```

Upload new firmware over the same serial port, without re-synthesising:

```bash
make bit-boot          # one-time: put the bootloader in the bitstream
make upload PORT=/dev/ttyUSB1
```

## Verification

Everything below was run in this repository:

- **Official `riscv-tests`, 60/60 pass** — `rv32ui` 41/41, `rv32um` 8/8,
  `rv32ua` 10/10, `rv32uc` 1/1. Run twice, once with `FAST_FETCH=1`
  (`--core s6`) and once with `FAST_FETCH=0` (`--core s6_sf`). Because the
  suite is built `-march=rv32imac`, every base-ISA test also exercises the
  RVC expander and the straddling fetch path.
- **`s6_muldiv_tb`** — 2200 randomised checks against a reference model,
  including the divide-by-zero and signed-overflow rules.
- **`s6_uart_tb`** — framing at several divisors, parity, FIFO levels,
  watermark interrupts, error flags.
- **`s6_soc_tb`** — boots the real firmware on the whole SoC with a
  behavioural IS61WV5128BLL attached, decodes the serial output off the `tx`
  pin, types into the echo loop. All eight on-target self-tests pass (M, A,
  Zicntr, traps, user mode, timer IRQ + `wfi`, UART loopback, SRAM).
- **`s6_boot_tb`** — uploads a program over the serial protocol and checks it
  runs.
- **`make lint`** — the SoC *and* the FPGA top elaborate, so a mistyped port
  in `s6_top.v` fails here rather than in synthesis.

`rv32ui-ma_data` is a documented exception: it expects misaligned accesses to
be *emulated*, and this core raises the architecturally correct misaligned
exception instead. The runner lists it as a known gap.

### Not verified here

- **No utilization or Fmax numbers.** ISE is not installed in this
  environment, so nothing in this README is a measured LUT count or timing
  result. The only figure that follows from the design rather than from
  synthesis is block RAM: 4096 words × 32 bits is 8 `RAMB16BWER` in 512×36
  mode, a quarter of the LX9's 32.
- **Not run on hardware.** The pin assignments come from the board's own UCF,
  but nothing here has been on a real Posedge One. If the serial console
  produces nothing, the first thing to try is swapping `p104`/`p105` — the
  FT2232's TX/RX naming is a coin flip on most boards.

## Configuration

Core (in `s6_soc`/`s6_top`): `ENABLE_M`, `ENABLE_A`, `ENABLE_C`, `ENABLE_U`,
`MUL_DSP`, `FAST_FETCH`, `RESET_ADDR`.
SoC: `CLK_HZ`, `BAUD`, `MEM_WORDS`, `MEM_INIT`, `GPIO_W`, `ENABLE_SRAM`.

`CLK_HZ` must match what the PLL in [`s6_clkgen.v`](rtl/s6_clkgen.v) actually
produces (24 MHz × 32 ÷ 16 = 48 MHz by default), or the baud divisor and the
CLINT's microsecond tick will both be wrong.

## Known limits

- Peripheral registers are word-access only; a byte store to a control
  register writes the whole word.
- No PMP, no MMU, no S mode. U mode without PMP means user code can still
  reach any address — it is privilege separation for traps and CSRs, not
  memory protection. The parent tutorial's `cpu_mc_s`/`csr_s` cover S mode
  and `mmu.v` covers Sv32.
- `fence` and `fence.i` decode and retire as no-ops. There are no caches, and
  the fetch and data ports are two ports of the same array, so there is
  nothing to flush.
- The external SRAM is a data region only; code runs from block RAM.
- One hart. `lr`/`sc` track a single reservation address, which is all a
  single-hart system needs.
