# Step 11 — Adding peripherals (UART, timer) via memory-mapped I/O

A CPU on its own can only compute and touch memory. To talk to the outside
world — print characters, measure time, blink an LED — it needs **peripherals**.
This step shows the standard mechanism for attaching them: **memory-mapped I/O
(MMIO)** with an address-decoding **bus**, turning the CPU into a small
system-on-chip (SoC).

New files:
- `rtl/cpu_core.v` — the CPU with its data port exposed as a bus
- `rtl/uart.v`, `rtl/timer.v`, `rtl/syscon.v` — the peripherals
- `rtl/soc.v` — the bus / address decoder that ties it all together
- `sw/soc_demo.c` — a C program that drives the peripherals
- `tb/soc_tb.v` — runs it

## The idea: peripherals look like memory

The RISC-V load/store instructions are the *only* way the CPU reaches outside
its registers. So rather than invent new instructions for I/O, we make
peripherals respond to ordinary loads and stores at **reserved addresses**.
Writing to address `0x1000_0000` doesn't hit RAM — it hits the UART's transmit
register. Reading `0x1001_0000` returns the timer's current count. To software,
a peripheral is just a special region of the address space; this is *all* that
"memory-mapped" means.

## What has to change: insert a bus

Until now the CPU owned its data memory directly. With multiple devices, we
need something between the CPU's data port and the devices that looks at each
address and routes the access to the right one. That something is the **bus**
(here, a simple combinational **address decoder**).

So we make two structural changes:

1. **Expose the CPU's data port** (`rtl/cpu_core.v`). This is `rtl/cpu.v` from
   Step 07 with the internal `dmem` instance removed and its four signals
   promoted to ports:
   ```verilog
   output wire [31:0] dmem_addr;     // where
   output wire [31:0] dmem_wdata;    // what to write
   output wire        dmem_we;       // write?
   output wire [2:0]  dmem_funct3;   // size (byte/half/word)
   input  wire [31:0] dmem_rdata;    // read data comes back from the bus
   ```
   Nothing else about the datapath changes — the data memory simply moved
   *outside* the core. (Instruction fetch stays inside as a ROM.)

2. **Add a top-level `soc.v`** that connects the core's bus to RAM and the
   peripherals through the decoder.

## The memory map

We assign each device a range. The exact numbers are arbitrary; what matters is
that they don't overlap and are easy to decode from a few high bits:

| Address range | Device | Registers |
|---------------|--------|-----------|
| `0x0000_0000`–`0x0FFF_FFFF` | RAM (4 KB) | the data/stack region |
| `0x1000_0000`–`0x1000_FFFF` | UART | `+0` TX, `+4` STATUS |
| `0x1001_0000`–`0x1001_FFFF` | TIMER | `+0` MTIME, `+4` MTIMECMP, `+8` EXPIRED |
| `0x2000_0000`–`0x2FFF_FFFF` | SYSCON | write to halt the sim |

## The address decoder

In `soc.v`, a few comparisons produce one **select line** per device:

```verilog
wire sel_ram   = (daddr[31:28] == 4'h0);
wire sel_uart  = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b0);
wire sel_timer = (daddr[31:28] == 4'h1) && (daddr[16] == 1'b1);
wire sel_sys   = (daddr[31:28] == 4'h2);
```

The top nibble picks the broad region; for the two devices that share region
`0x1`, bit 16 distinguishes UART (`0x1000_xxxx`) from TIMER (`0x1001_xxxx`).
Decoding only a few bits keeps the logic tiny — a real bus does the same, just
with more devices.

Writes are gated by the select line (so only the addressed device's `we`
fires), and reads are chosen by a mux:

```verilog
dmem #(.BYTES(4096)) u_ram   (.we(dwe && sel_ram),   ... , .rdata(ram_rdata));
uart              u_uart   (.sel(sel_uart),  .we(dwe && sel_uart),  ...);
timer             u_timer  (.sel(sel_timer), .we(dwe && sel_timer), ...);
syscon            u_syscon (.sel(sel_sys),   .we(dwe && sel_sys),   ...);

assign drdata = sel_uart  ? uart_rdata  :
                sel_timer ? timer_rdata :
                            ram_rdata;
```

Notice the RAM is just our existing `dmem` block, reused unchanged — it already
has the right interface. New devices simply join the same pattern: add a select
line, gate its write enable, and add it to the read mux.

## The peripherals

Each is small. They share a tiny "slave" interface: `sel`, `we`, an offset
`addr`, `wdata`, and a combinational `rdata`.

**UART** (`rtl/uart.v`) — a write to offset 0 prints the low byte; reading
offset 4 returns a "ready" status:
```verilog
always @(posedge clk)
    if (sel && we && addr[3:0]==4'h0)
        $write("%c", wdata[7:0]);     // "transmit" = print in simulation
```
A real UART would shift the byte out a pin at a baud rate; `$write` is the
simulation stand-in that gives us console output.

**TIMER** (`rtl/timer.v`) — a free-running counter you can read, plus a
compare register and an "expired" flag for polling:
```verilog
always @(posedge clk)
    if (rst) mtime <= 0; else mtime <= mtime + 1;   // ticks every cycle
// reads: +0 -> mtime, +4 -> mtimecmp, +8 -> (mtime >= mtimecmp)
```

**SYSCON** (`rtl/syscon.v`) — a write halts the simulation with an exit code,
so programs decide when they're done instead of the testbench guessing a cycle
count:
```verilog
always @(posedge clk)
    if (sel && we) begin $display("exit %0d", wdata); $finish; end
```

These are **simulation models**: `$write`/`$finish` describe behavior, not
synthesizable hardware. On a real FPGA you'd replace them with actual UART
serializer logic, a hardware counter, etc. — but the *bus and decoder around
them stay exactly the same*, which is the whole point.

## Driving them from C

`sw/soc_demo.c` accesses each device through a `volatile` pointer at its
address — the C idiom for MMIO:

```c
#define UART_TX (*(volatile unsigned char *)0x10000000)
#define TIMER   (*(volatile unsigned int  *)0x10010000)
#define SYSCON  (*(volatile unsigned int  *)0x20000000)

static void uart_putc(char c) { UART_TX = (unsigned char)c; }

int main(void) {
    uart_putc('R'); uart_putc('V'); /* ... */ uart_putc('\n');
    unsigned t0 = TIMER;
    for (volatile int i = 0; i < 5; i++) { }
    unsigned t1 = TIMER;
    *(volatile unsigned *)0 = t1 - t0;   // leave the delta in RAM
    SYSCON = 0;                          // halt
}
```

`volatile` is essential: it tells the compiler each access is a real I/O event
that must happen, in order, and must not be optimized away or cached in a
register. Without it, the compiler would "helpfully" delete the repeated TIMER
reads or merge the UART writes.

(The demo uses character literals rather than a string constant, because string
constants live in `.rodata`, which this core doesn't preload into RAM — the
same initialized-data limitation noted in Step 10.)

## Run it

```bash
make soc
```

Output:

```
---- UART output ----
RV32I OK
[syscon] halt requested, exit code = 0
timer delta measured by program = 32 cycles
```

The CPU printed through the UART, read the timer twice, computed the elapsed
cycles, and stopped itself through the syscon device. You now have a programmable
SoC, not just a CPU.

## Adding your own peripheral

The pattern generalizes. To add, say, a GPIO output port:

1. Write `rtl/gpio.v` with the `sel/we/addr/wdata/rdata` interface; a write
   latches `wdata` into an output register, a read returns it.
2. In `soc.v`: pick an address range, add `wire sel_gpio = ...`, instantiate it
   with `.we(dwe && sel_gpio)`, and add `gpio_rdata` to the read mux.
3. Access it from C through a `volatile` pointer at its address.

That's it — three steps, and the CPU never changes.

## What this still can't do: interrupts

Everything here is **polled**: software actively reads STATUS/EXPIRED in a loop.
Real systems use **interrupts** so a peripheral can signal the CPU
asynchronously (e.g. "a byte arrived", "the timer fired"), and the CPU jumps to
a handler. Interrupts require machinery this core doesn't have:

- **CSRs** (control/status registers): `mstatus`, `mie`, `mip`, `mtvec`,
  `mepc`, `mcause`, accessed via the `csrr*` instructions (the "Zicsr"
  extension).
- **Trap logic** in the datapath: on an interrupt, save the PC to `mepc`, jump
  to the handler address in `mtvec`, and return with `mret`.

Adding those is the natural next big project, and it's what separates a
teaching core from one that can run an RTOS. Until then, polled peripherals —
which is what most bare-metal bring-up code uses anyway — work great.

## Checkpoint

You've extended the CPU into an SoC: a bus with an address decoder, a UART, a
timer, and a halt device, all driven from C through memory-mapped I/O. Adding
more peripherals is now a mechanical, three-step pattern.
