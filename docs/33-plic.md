# Step 33 — A PLIC (platform-level interrupt controller)

Up to now "external interrupt" meant a single wire. Step 31 ran the UART's
interrupt straight into the core's `MEIP`. That works for one device, but as
soon as there are several — a UART, a timer-capture line, a couple of GPIOs —
they all have to share that one bit. ORing them together tells the core *an*
interrupt happened but not *which*, gives no way to say one is more urgent than
another, and offers no clean way to mask a noisy source. This step builds the
RISC-V answer to that: a **PLIC**, which multiplexes many source lines into the
one `MEIP` with per-source priority, enables, a threshold, and a claim/complete
handshake so software always knows exactly what it is servicing.

## The five mechanisms

`rtl/plic.v` is a compact one-hart, M-mode PLIC with these registers:

- **Priority** — one value per source (`0x0000 + 4*i`). `0` means "never
  interrupt"; higher wins. Priority is what lets a timer pre-empt a chatty UART.
- **Pending** — a read-only bitmap (`0x1000`). A *gateway* per source latches the
  line into a pending bit; that bit is what the arbiter looks at.
- **Enable** — a writable bitmap (`0x2000`). A masked source can still go pending
  but is never presented to the hart.
- **Threshold** — one value (`0x3000`). Only sources whose priority is strictly
  greater than the threshold are eligible. Raising it to 4 silences everything at
  priority 4 or below without touching the individual enables.
- **Claim / complete** — one register (`0x3004`). *Reading* it returns the id of
  the highest-priority eligible source and atomically clears that source's
  pending bit (a claim); reading `0` means nothing is pending. *Writing* the id
  back signals the device is serviced (a complete), so it may interrupt again.

The arbiter is a single combinational pass: among sources that are pending,
enabled, and above threshold, pick the highest priority, with the lowest id
winning ties (a strict `>` while scanning low-to-high id does exactly that). Its
OR-reduction is the `meip` line into the core. So several lines really do become
one `MEIP`, and software recovers the detail through claim.

## The gateway, and why it has two state bits

Each source carries a `pending` bit and an `in-service` bit. The gateway latches
`pending` when the line is asserted and the source is neither already pending nor
in service. A claim clears `pending` and sets `in-service`; a complete clears
`in-service`. The `in-service` bit is what stops a level-held line (like the
UART's, which stays high until the device is read) from being re-claimed over and
over inside its own handler — it can only re-pend after complete, and only if the
line is still asserted. The same gateway handles a brief pulse (it latches once
and, the line having gone low, does not re-pend after complete). The demo's
external lines are pulses; the UART is the level case.

## The subtle hardware bug this step flushed out

A claim is a *read with a side effect*: the act of reading mutates state. On this
multi-cycle core `dmem_addr = alu_result` is driven on **every** instruction, not
only loads — so the `addi a5,a5,4` that *computes* the claim address `0x10023004`
puts that address on the bus for a cycle, with write-enable low. That is
indistinguishable, on the bus alone, from the `lw` that actually reads the claim
register. The PLIC duly fired a claim for the `addi`, consumed the highest-
priority source, and the real load a few cycles later got the *second* one. The
symptom was a claim sequence of `3,4,4,…` instead of `3,4,2`.

The fix is the right one for any bus with read-side-effects: a **read strobe**.
`cpu_mc` now exposes `dmem_re`, asserted only during a genuine load (`mem_read`
in EXEC/MEM), and the SoC qualifies every peripheral select with
`dvalid = dmem_re | (writes)`. A coincidental ALU result can no longer be
mistaken for a memory transaction. The claim itself is additionally edge-detected
inside the PLIC and latched into `claimed_reg`, so the value stays stable across
the load's two bus cycles (EXEC presents it, MEM is where the core samples it)
and the claim takes effect exactly once. This is also why a real PLIC claim is
specified as a side-effecting read rather than a plain register: the hardware has
to know a claim genuinely happened.

## What the demo shows

`make plic` runs `soc_plic` (cpu_mc + UART on source 1 + three external lines on
sources 2–4 + the PLIC). The firmware sets priorities `src2=3, src3=7, src4=5`,
enables all four, points `mtvec` at an ISR, and turns on `MEIE`/`MIE`. The ISR
drains the controller: `while ((id = CLAIM)) { record(id); CLAIM = id; }`.

Phase 1 pulses all three external lines in the same cycle. One `MEIP` rises; the
ISR claims them back in priority order **3, 4, 2** (priorities 7, 5, 3) and
completes each. Phase 2 raises the threshold to 4 and pulses again: only sources with priority
above 4 — `src3` (7) and `src4` (5) — are admitted and claimed **3, 4**, while
`src2` (priority 3) stays latched in the pending register (`0x4`) but is never
presented. That is the whole point of a
threshold: mask by urgency without losing the request.

## What's verified here

`make plic` checks the phase-1 claim order, the phase-2 claim order under
threshold, and that the masked source remains pending — printing `PLIC: ALL
PASS`. The read-strobe change is exercised by the full regression below; the
existing SoCs that instantiate `cpu_mc` simply leave the new `dmem_re` output
unconnected, so nothing else changed.

## Honest status

- One hart, M-mode, four sources, 3-bit priorities — enough to show every
  mechanism. A real PLIC supports many harts and contexts (M and S per hart),
  up to 1023 sources, and lays the registers across a 64 MB window (threshold and
  claim live at `0x20_0000 + 0x1000*context`). This keeps the same *semantics* in
  a compact window so the demo fits the existing address map.
- The gateway is the simple level/pulse hybrid described above; it does not
  implement the spec's separate edge-vs-level configuration per source.
- Verified in simulation only. The arbiter is a combinational scan over four
  sources; at a large source count you would pipeline or tree it to keep it off
  the critical path.
- The claim's read-side-effect correctness depends on the new `dmem_re` strobe.
  Any future peripheral with a side-effecting read must qualify on it too — the
  bug above is the cautionary tale.

## Takeaway

A single interrupt wire answers "did something happen?"; a PLIC answers "what,
how urgent, and is it mine to handle yet?" The machinery is small — a priority
per source, two bitmaps, a threshold, and one magic register — but it turns a
shared line into an ordered, maskable queue, and the claim/complete handshake is
what lets the handler name precisely the device it is servicing. The detour
through the spurious-claim bug is the real lesson of the step: a read that
changes state is only safe when the hardware can tell a true access from an
address that an ALU happened to compute.
