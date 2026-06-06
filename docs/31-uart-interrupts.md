# Step 31 — UART interrupts and receive-to-idle

Polling a UART works, but it ties the CPU to a spin loop: it can't do anything
useful while it waits for the next byte. Interrupts invert that — the UART taps
the CPU on the shoulder only when something happens. This step adds a machine
**external interrupt** to the core, wires the UART to it, and then adds the one
feature that makes variable-length messages easy: an **idle-line** ("receive to
idle") interrupt that fires when the line goes quiet after a burst, telling the
CPU "the whole message has arrived" without it ever needing to know the length in
advance. It's the same idea STM32's `ReceiveToIdle` HAL call is built on.

## A second interrupt source in the core

So far the only interrupt the core understood was the machine **timer** (cause
`0x80000007`, pending bit `MTIP` / enable `MTIE`, both bit 7). RISC-V reserves a
second standard machine interrupt for everything external to the core: the
machine **external interrupt**, cause `0x8000000B`, pending bit `MEIP` and enable
`MEIE`, both bit 11.

`rtl/csr.v` gains an `ext_irq` input and an `irq_cause` output:

```
wire ext_fire   = mie[11] & ext_irq;       // MEIE & line
wire timer_fire = mie[7]  & timer_irq;      // MTIE & line
irq_pending = mstatus.MIE & (ext_fire | timer_fire);
irq_cause   = ext_fire ? 0x8000000B : 0x80000007;   // external wins
```

External is given priority over the timer, matching the RISC-V ordering
(MEI > MSI > MTI). The change is backwards-compatible: every other core ties
`ext_irq` low, so `irq_cause` is always `0x80000007` for them and nothing about
the timer path changes. `mip` now reflects both lines (`MEIP` at 11, `MTIP` at 7).

`rtl/cpu_mc.v` — the core the FPGA SoCs use — gets an `ext_irq` port that feeds
the CSR, and uses `irq_cause` instead of a hard-wired timer cause when it takes an
interrupt trap.

### A multi-cycle interrupt bug this surfaced

Adding a *frequent* interrupt source exposed a latent hazard in the multi-cycle
core that the (rare, periodic) timer had never tickled. `cpu_mc` sequences a load
over three cycles: FETCH → EXEC → **MEM**. The next-PC mux was shared across all
states and selected `mtvec` whenever `take_trap` was high — but the CSR only
*records* a trap (saves `mepc`, clears `MIE`) during EXEC. If an interrupt became
pending while a load was sitting in its MEM cycle, the datapath would jump to the
handler while the CSR quietly did nothing. The handler's first instruction then
took the *same* interrupt again, this time capturing `mepc` = the handler entry.
On return that `mret` jumped back into the handler as if it were ordinary code,
and a few iterations later the privilege stack underflowed to User mode, where
`mret` is illegal — an infinite trap loop.

The fix is to only let a trap (or `mret`) redirect the PC in EXEC:

```
wire trap_take = take_trap & in_exec;       // act on traps only at EXEC
... if (trap_take) next_pc = mtvec; else if (is_mret & in_exec) ...
```

A load caught mid-MEM now simply completes (`pc+4`); the still-pending interrupt
is taken cleanly at the *next* instruction boundary. This is the correct precise-
interrupt behaviour, and it's why interrupt-driven I/O — not just a periodic tick
— is a good stress test of a core's trap logic.

## The UART side: three new registers

`rtl/uart_full.v` keeps its byte registers (TXDATA/RXDATA/STATUS/CONFIG) and adds:

| Offset | Name    | Bits | Meaning                                                       |
|-------:|---------|------|--------------------------------------------------------------|
| `0x10` | IEN     | RW   | b0 RX-not-empty IE · b1 IDLE IE · b2 TX-empty IE             |
| `0x14` | IPEND   | R/W1C| b0 RX (`rx_valid`) · b1 IDLE (latched) · b2 TX (`tx_ready`)  |
| `0x18` | IDLECFG | RW   | `[4:0]` idle bit-times before an IDLE event (0 disables)      |

The peripheral raises one `irq` line, level-sensitive:

```
irq = (rx_valid & IEN.rxne) | (idle_pend & IEN.idle) | (tx_ready & IEN.txe)
```

RX-not-empty clears when software reads `RXDATA`; the IDLE event is *latched* in
`idle_pend` and cleared by writing 1 to `IPEND` bit 1 (write-1-to-clear). In
`rtl/soc_uart_fpga.v` that `irq` is wired straight to `cpu_mc.ext_irq`.

## Idle-line detection

The receiver in `rtl/uart_rx.v` grows a small second counter. Once at least one
byte has been received, it counts how long the line stays idle (high, no new
start bit) in units of bit-periods. When that reaches `idle_bits`, it pulses
`idle` for one cycle and arms again only after the next byte. Any new start bit
resets the count, so a continuous stream never trips it — only a *gap* does. With
`idle_bits = 12` (a little over one 8N1 frame), the event means "the sender has
stopped talking", which is exactly the boundary of a message.

## The receive-to-idle pattern

`sw/uart_irq_demo.c` puts it together. The handler is an ordinary C function
marked `__attribute__((interrupt("machine")))`, so the compiler emits the
register save/restore and the `mret` for us; `mtvec` is pointed at it.

```c
void __attribute__((interrupt("machine"))) trap_handler(void){
    unsigned p = IPEND;
    if (p & IP_RXNE) rxbuf[rxlen++] = RXDATA;          // a byte -> buffer
    if (p & IP_IDLE){                                  // line went quiet
        msg_len = rxlen; rxlen = 0; msg_ready = 1;     // whole message ready
        IPEND = IP_IDLE;                               // W1C the idle event
    }
}
```

`main` enables `MEIE` + global `MIE`, sets `IEN = RXNE | IDLE`, and then just
watches a flag: when `msg_ready` goes up it echoes `rxbuf[0..msg_len)` back. The
CPU spends the rest of its time free; each byte and the end-of-message arrive as
interrupts. `tb/uart_irq_tb.v` drives two whole messages ("HELLO", then "Hi!")
back-to-back and checks each is collected and echoed in full — including the
nasty case where the second message's first byte interrupts the first message's
tail, which is what flushed out the multi-cycle bug above.

## What's verified here

`make uart-irq` builds the firmware and runs the end-to-end simulation: the host
sends a burst, the SoC takes one RX interrupt per byte, the IDLE interrupt fires
when the burst ends, and the firmware echoes the entire message. Both messages
pass. The timer-interrupt regression (`irq`, `clint`, `rtos-smoke`,
`freertos-fpga-run`) still passes, confirming the core change is safe — FreeRTOS,
which lives entirely on timer-tick preemption on this same `cpu_mc`, completes its
queue demo unchanged.

## Honest status

- Simulation uses `clks_per_bit = 64` so the handler comfortably finishes between
  bytes. On the Zynq-7010 build `uart_irq_demo.c` with `-DCLKS=1085`
  (115200 @ 125 MHz) and leave `DEF_IDLE = 12`; match your terminal's framing.
- The RX path is still one byte deep with an overrun flag. Interrupt-per-byte is
  fine at console rates, but at high baud with a slow ISR you can overrun between
  bytes; a 16/32-deep FIFO behind the same `rx_valid`/IDLE interface is the
  upgrade, and would also let IDLE delimit much faster bursts.
- There's no interrupt *controller* (PLIC): the single UART line is the only
  external source, ORed straight into `MEIP`. Multiple peripherals would want a
  PLIC (or a simple priority encoder) to multiplex and identify the source.
- The `interrupt` attribute saves caller-saved registers on the current stack; a
  deep call chain inside the ISR shares `main`'s stack. For this demo that's fine;
  an RTOS would give interrupts their own stack.
- As always, the logic is verified in iverilog; pin mapping and 125 MHz timing
  closure must still be checked in Vivado against your board's XDC.

## Takeaway

Two ideas carry this step. First, interrupts are only as correct as the
instruction boundary they're taken on — a periodic timer can hide a trap-timing
bug for a long time, but a byte-rate source will find it, so take traps at one
well-defined point (here, EXEC) and let in-flight memory accesses retire. Second,
"receive to idle" turns an open-ended question ("how long is the message?") into a
hardware event: watch the line go quiet, latch it, and let the CPU read a complete
message in one shot. Together they're what lets a small core handle a serial
protocol while still getting real work done.
