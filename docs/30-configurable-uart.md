# Step 30 — A configurable UART with a receive path

Until now the UART could only *talk* (TX, fixed 8N1). Real serial links need to
*listen* too, and to agree on framing: baud rate, how many data bits, whether
there's a parity bit, and how many stop bits. This step adds a receiver and makes
all four settings configurable at run time, then runs it on the Zynq-7010.

## The modules

**`rtl/uart_rx.v`** — the receiver. An asynchronous serial line is sampled with a
2-flop synchronizer, then a small state machine recovers each byte:

- wait for the falling edge of the **start bit**;
- re-sample at the *middle* of the start bit to reject glitches;
- sample each **data bit** at its centre (one baud period apart), LSB first;
- if parity is enabled, sample the **parity bit** and compare it against the
  running XOR of the data bits (even) or its complement (odd) → `parity_err`;
- check the **stop bit(s)** are high → `frame_err`;
- pulse `valid` for one cycle with the assembled byte.

**`rtl/uart_tx_cfg.v`** — the transmitter, same framing knobs, so a receiver and
transmitter that share a config can be wired back-to-back and verified by
loopback.

Both take the framing as *inputs*, not just parameters:

| input | meaning |
|---|---|
| `clks_per_bit` | baud divisor = f_clk / baud |
| `data_bits` | 5–8 |
| `parity_mode` | 0 = none, 1 = odd, 2 = even |
| `stop2` | 0 = one stop bit, 1 = two |

**`rtl/uart_full.v`** — the MMIO peripheral that wraps both, with a `CONFIG`
register so software sets the framing at run time:

```
  0x00 TXDATA (W)  write a byte to send (when tx_ready)
  0x04 RXDATA (R)  received byte; reading clears rx_valid and the error flags
  0x08 STATUS (R)  bit0 tx_ready  bit1 rx_valid  bit2 frame_err
                   bit3 parity_err bit4 overrun
  0x0C CONFIG (RW) [15:0] clks_per_bit  [19:16] data_bits
                   [21:20] parity        [22] stop2
```

A one-byte holding register with an `overrun` flag sits between the receiver and
the bus; reading `RXDATA` consumes the byte.

## On the Zynq-7010

`rtl/soc_uart_fpga.v` drops `uart_full` into the synthesizable multi-cycle BRAM
SoC (the same `cpu_mc` core used for the FreeRTOS-on-FPGA build), and
`rtl/fpga_top_uart.v` is the board top. `constraints/zynq7010_uart.xdc` adds a
`uart_rx` pin (Pmod JE2) next to the existing `uart_tx` (JE1):

```
  adapter RX  <-- uart_tx (JE1)
  adapter TX  --> uart_rx (JE2)
  adapter GND <-- board GND
```

The demo firmware `sw/uart_echo.c` configures the UART to 8N1 and echoes every
byte it receives — the classic way to prove a serial port works end to end.

## What's verified here

**Module loopback** (`make uart-loopback`) wires the configurable TX into the RX
and pushes bytes through several framings, plus a deliberate mismatch:

```
8N1:  55->55, a3->a3, 00->00, ff->ff      (parity_err=0)
7E1:  55->55, 2a->2a                       7-bit + even parity
8O2:  a3->a3, 10->10                        8-bit + odd parity + 2 stop
5N1:  15->15, 0a->0a                        5-bit
baud change (clks=24): 5a->5a
parity MISMATCH (tx even, rx odd): parity_err=1   <- error correctly flagged
UART LOOPBACK: ALL PASS
```

**End-to-end through the CPU** (`make uart-echo`) runs `uart_echo` on the
synthesizable SoC while the testbench plays the host — its own TX drives the SoC's
`uart_rx` pin, its own RX captures the SoC's `uart_tx` pin:

```
sent 'H' (48) -> echoed 'H' (48)
sent 'i' (69) -> echoed 'i' (69)
sent '!' (21) -> echoed '!' (21)
sent 'Z' (5a) -> echoed 'Z' (5a)
UART ECHO: ALL PASS
```

That single test exercises the whole path: the CPU writes `CONFIG`, the receiver
recovers each byte from the wire, the firmware reads `RXDATA` and writes `TXDATA`,
and the transmitter sends it back — all on the core that targets the 7010.

## Honest status

- Simulation uses a tiny baud divisor (`clks_per_bit = 16`) so frames are short.
  For real hardware keep `DEF_CLKS = 1085` (115200 @ 125 MHz) and build
  `uart_echo` without `-DCLKS=16` (it defaults to 1085); set both the FPGA and
  your terminal to the same framing.
- The RX holding register is one byte deep with an overrun flag — fine for
  echo/console use and interrupt- or poll-driven drivers at modest rates. A FIFO
  (depth 16/32) is the natural upgrade for back-to-back bursts at high baud, and
  drops in behind the same `rx_valid`/`RXDATA` interface.
- No hardware flow control (RTS/CTS) and no automatic baud detection; framing is
  whatever software writes to `CONFIG`.
- As always here, the RX/TX timing and the BRAM SoC are verified in simulation;
  pin assignments and 125 MHz timing closure must be checked in Vivado against
  your board's master XDC.

## Takeaway

Receiving is the mirror of sending plus one idea: don't sample on the clock edge,
sample in the *middle* of each bit, where the line is most settled. Lift the
framing constants into a register and the same state machine speaks 9600-7E1 or
3 Mbaud-8N1 with no RTL change — the difference is just a number the CPU writes.
