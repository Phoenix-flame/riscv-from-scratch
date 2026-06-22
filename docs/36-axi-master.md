# Step 36 — An AXI4-Lite master to the PS: a stall-capable bus

Every memory this core has talked to until now answers instantly. Block RAM has a one-cycle registered read, so the multi-cycle core presents a load address in EXEC and simply finds the word waiting in MEM. That assumption — *the data is always there next cycle* — is baked into the FSM, and it is false for almost everything outside the FPGA's own block RAM. A peripheral in the Zynq PS, a transfer crossing into the PS over an AXI-GP port, a read from the DDR controller: these answer when they answer, after a handshake that can take an arbitrary number of cycles. To reach any of them the core has to learn to wait.

This step adds that ability and then uses it. First a stall-capable core, `cpu_mc_stall`, which gains a single new input — `dmem_ready` — and the discipline to hold a memory access until the slave raises it. Then a bus-to-AXI adapter, `axi_lite_master`, which turns one request on the core's simple bus into a full five-channel AXI4-Lite transaction and pulls `dmem_ready` low until the response comes back. A SoC wires a high address window through that master out to the PS, and a deliberately slow AXI slave model stands in for the PS so the whole path can be exercised in simulation.

## What "the data is always there" was hiding

The original bus is not really a protocol — it is a set of wires the core drives and a memory that is assumed fast enough to keep up. There is no signal that means "not yet." Adding one changes the contract from *fixed latency* to *handshake*: the core asserts a request and keeps it asserted; the slave asserts ready exactly when the transfer completes; for a read, the data is valid on that same ready cycle. A block RAM satisfies this trivially by tying ready high — it is always done — and behaves as before. Anything slower simply leaves ready low for as many cycles as it needs, and the core sits still.

In the multi-cycle FSM this lands almost entirely in the MEM state. Loads already passed through MEM; now stores do too, so that both kinds of access share one path that can stall. The core enters MEM, asserts its request there — and *only* there, never in EXEC — and stays until `dmem_ready`. Asserting the request strictly in the MEM phase matters for the same reason the PLIC step needed a read strobe: `dmem_addr` is driven on every instruction from the ALU result, and a variable-latency slave with side effects must not see a phantom access from an instruction that merely computed an address that looked like its own. By construction here, the AXI master is kicked off only when the access genuinely commits.

One consequence is worth stating: a store now costs the same three cycles a load does, where before it finished in two. That is the price of giving stores a path that can wait for a write to be accepted, and it is the right trade — a store to a PS register has to wait for the bus just as much as a load does.

A second, quieter property falls out of where traps are taken. The core only takes an interrupt or exception in EXEC, never in MEM. So an interrupt that becomes pending in the middle of a long AXI transfer cannot abort it: the transfer drains, the instruction retires, and the interrupt is taken at the next instruction's EXEC. The in-flight bus access is never left half-finished, which is exactly what a real AXI slave requires — once you have issued the address, you must consume the response.

## The five channels, and why there are five

AXI splits a memory access into independent channels, each a simple valid/ready handshake: a write address channel (AW), a write data channel (W), a write response channel (B), a read address channel (AR), and a read data channel (R). The separation is what lets a real interconnect pipeline and reorder traffic, but even at its simplest the structure has a logic to it: address and data travel separately so they can be produced at different times, and the B channel exists so a write can be acknowledged — a write is not complete when the data is accepted, only when the slave confirms it landed.

The adapter is a small state machine that serializes one core request onto these channels. A write drives AW and W together, waits for each to be accepted (they are independent, so it tracks them separately), then waits on the B response before telling the core the store is done. A read drives AR, waits for it to be accepted, then waits on R, latches the returned word, and releases the core. A short settling state at the end guarantees the core has dropped its request before the adapter is willing to start another, so a held request can never be mistaken for a second transaction. The whole thing is AXI4-Lite: one 32-bit beat per transaction, byte strobes for sub-word writes, no bursts.

## What the PS looks like from the PL

On a real Zynq the AXI master pins leave the programmable logic and connect to a slave port on the processing system — an AXI-GP port into the PS peripherals, or a port into the DDR memory controller. The SoC here exposes exactly those pins at its boundary and maps a high address window, `0x4000_0000`, to the master; everything below stays local block RAM and the SYSCON halt register, which answer in one cycle with ready tied high. The address decode picks which: a data access in the PS window routes its ready and read-data from the AXI master, and the master only completes when the far end responds.

In simulation the far end is `axi_lite_slave_mem`, a model that behaves like a slow PS: it makes the address channels wait several cycles before accepting, and the response channels wait several more before answering. It is intentionally sluggish so that the core spends real time stalled, and so a passing test is evidence the handshake — not a lucky fixed delay — is what carries the data. On real hardware this model is replaced by the PS block, with no change to the PL-side RTL.

## What the demo shows

`make axi` runs a small C program on `soc_axi`. It writes sixteen words into the PS window, reads all sixteen back and sums them, does a read-modify-write on another PS location, and checks that a specific read returns the value written earlier — then leaves its results in local RAM and halts. Every one of those PS accesses goes out over AXI and stalls the core until the slave responds; the program is written as ordinary loads and stores and is entirely unaware that some of its memory lives across a handshake. The testbench confirms the computed results (the DDR sum, the read-modify-write giving 123, the read-back check) and also reaches into the slave's memory to confirm the writes actually arrived there — proof the AXI write path, not just the read path, is correct.

`make axi-lite` is the focused test underneath it: it drives the adapter's core-side request directly against the wait-state slave and checks write/read round-trips, and it asserts that a read takes more than a handful of cycles — that the access is genuinely completing on the slave's schedule rather than a fixed one. The measured round-trip is eleven cycles through this particular slave's wait states.

## What's verified here

The adapter test checks AXI4-Lite write-then-read round-trips through a slave that injects wait states on every channel, and confirms the transaction latency tracks the slave rather than a fixed pipe. The SoC test runs a compiled program whose results only come out right if reads and writes both round-trip correctly through the stalls, checks those results in local RAM, and independently confirms the written data landed in the slave's memory. The stall-capable core executes the full program — loop, arithmetic, branches, a read-modify-write — correctly while interleaving one-cycle local-RAM accesses with many-cycle AXI accesses. Because the step only adds files (`cpu_mc_stall`, `axi_lite_master`, `soc_axi`, and the testbenches) and changes no shared module, the rest of the regression is undisturbed.

## Honest status

- AXI4-Lite only: one 32-bit beat per transaction, no bursts. This is the right match for a core that issues one word at a time and is enough to reach PS peripherals and, functionally, DDR — but it gets one word per full handshake, so it is a correctness path, not a bandwidth path.
- Full AXI4 with bursts (the AXI-HP port, where DDR bandwidth actually lives) is deliberately not built. Bursts only pay off once something generates multi-beat requests — a cache line refill or a DMA engine — and there is neither yet. A D-cache is the natural prerequisite and the honest next step; with it, the adapter grows burst counters and `WLAST`/`RLAST` handling.
- The PS is a simulation model. It follows AXI4-Lite handshake ordering and injects latency, but it is not the real PS: no reordering, no outstanding-transaction depth, a single in-flight transaction at a time. The PL-side RTL is what would be carried to hardware unchanged; the model is replaced by the Zynq PS block.
- The adapter issues one transaction at a time and the core blocks on it. There is no write buffer and no overlap of independent accesses — again, the things a cache or DMA path would add.
- Verified in simulation only.

## Takeaway

The interesting part of talking to AXI is not the five channels — those are just handshakes — it is admitting that memory has latency the core does not control. Once the bus can say "not yet," the core needs exactly one new idea: hold the access, freeze the PC, and wait. Everything else, including reaching the entire PS — DDR and every peripheral behind it — is built on that one stall signal. The hardest line in this step is the FSM branch that does nothing until `dmem_ready`; the AXI master is bookkeeping around it.
