# Step 60 — A branch predictor for the board, in one block RAM

> **Followed by Step 61** (`docs/61-d-page.md`): loads and stores in the
> page of the last one spend one cycle in EX, not two.

Step 57 left the branch predictor out of the board build. The Step 32
predictor (`branch_predictor.v`) resets every entry, so it is about 3,800
flip-flops, and its lookup is combinational on the PC, in front of the
next PC. Without it every taken branch and jump costs a flush, three
cycles with `REG_REDIRECT`. In CoreMark on the board core that is 22 % of
the cycles.

`rtl/bpred_b.v` is the same predictor, a BTB and 2-bit counters, stored
the way Step 59's caches are. `BPRED=2` selects it, and the board build
now does.

## The result

On the board core with 16 + 16 KiB caches and memory latency 40
(`tools/bench --hw brd-c16k-l40`):

| | Step 59 | Step 60 |
|---|---|---|
| CoreMark/MHz | 1.854 | **2.289** (+23 %) |
| Dhrystone DMIPS/MHz | 0.747 | **0.934** (+25 %) |
| CoreMark flush cycles (40 iterations) | 4.66M | 0.58M |
| CoreMark mispredictions | 1,560,262 | 199,051 |
| block RAM | 16 RAMB36 + 2 RAMB18 | 17 RAMB36 + 2 RAMB18 |

## One block RAM, read a cycle ahead

Each of the 512 entries is `{tag, counter, target[31:2]}`, 53 bits, so one
RAMB36 holds the table in its 512 × 72 shape. It is read at the edge
before the fetch, at `pc_d`, the PC register's next value. In the cycle
that PC is fetched, the entry is already in the RAM's output register.
The prediction is then a tag compare against the PC, plus the counter's
high bit.

Nothing here has to be right, because EX checks every prediction. So there
is no valid bit and no reset clear. An entry that is not this PC's costs a
misprediction, whether it is left over from another program, aliased, or
read in the same cycle as its own update. The RAM starts at zero from
the bitstream, and a zero counter predicts nothing.

The counter is not read a second time to update it. The prediction's own
`{hit, counter}` (`info`) rides down the pipe with the instruction, and EX
hands it back with the outcome:

- **jal / jalr:** `{tag, 11, target}`.
- **A branch that hit:** `{tag, counter ± 1, target}`.
- **A taken branch that missed:** `{tag, 10, target}` (allocated weakly taken).
- **A not-taken branch that missed:** no write.

## Checking the target without an adder in front

With no predictor, a misprediction was simply "taken". With one, EX also
has to compare the target it computed against the predicted one. For a
`jalr` that compare sat behind forwarding, the ALU's adder and a 32-bit
equality, then into the registered redirect. It was the worst path on the
first build. Both kinds of target are now checked against values ID
works out:

- **Branch or jal:** the target is `pc + imm`, all known in ID.
  `idex_tgt_ok` registers whether it equals the prediction.
- **jalr:** it lands on the prediction exactly when `rs1 == predicted − imm`.
  ID registers that value (`idex_jx`), so EX compares the forwarded `rs1`
  against a register.

An odd `rs1` that would also land there (bit 0 is dropped) only counts as
a miss. A simulation-only check stops the run if a target counted as
right ever is not. The benchmark cycle counts did not change.

## The D-cache's promise and fetch walks

The other path the first build reported was from Step 59. The D-cache
reads a cycle ahead at a promised address (`d_hint_ok`), and the promise
held only if no page walk took the D-port. For a fetch walk, that meant
the PC's page compare (`IF_PAGE`), then "a walk starts", then the D-cache's
read index. With the PC now also feeding the predictor, that became the
worst path on most seeds.

Now a fetch walk does not start while a load or store is in EX. It waits
at most the cycles that load or store needs. The promise then depends
only on the walker being idle, which is a register.

| build | 8 seeds |
|---|---|
| Step 59 | 55.3–58.4 MHz |
| predictor, first version | 50.3–55.9 MHz |
| + target check from ID, D promise without fetch walks (and Step 61's D_PAGE) | 51.9–59.1 MHz |

## Checks

| check | result |
|---|---|
| riscv-tests on `pipe_u_board`, `pipe_u_board_vm`, `pipe_c_board_vm`, `pipe_c_uni_board` (`BPRED=2`) | 59 · 59 · 59 · 60, ALL PASS |
| riscv-tests on `pipe_u`, `pipe_c`, `pipe_u_vm`, `pipe_c_vm` (`BPRED=1`, unchanged) | 90 each, ALL PASS |
| mutant: every jalr target counted right | the simulation-only check stops it, 2 tests fail |
| `tools/bench` | results verified, as above |
| U-Boot + Linux on the board configuration | LINUX: ALL PASS, mispredictions 1.4M; flush cycles 52.0M → 3.2M |
