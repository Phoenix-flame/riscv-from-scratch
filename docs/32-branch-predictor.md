# Step 32 — A branch predictor (BTB + 2-bit counters)

The pipelined core (Step 14) resolves branches in EX, three stages after fetch.
Until now it guessed *not-taken*: it keeps fetching straight past a branch, and
when the branch turns out taken it throws away the two instructions it fetched
behind it. That's a fixed two-cycle bubble on **every** taken branch — and most
branches that matter (loop back-edges) are taken almost every time. This step
adds a real branch predictor so the common case costs nothing, and measures how
much it actually helps.

## What a predictor has to produce, and when

The hard part is *timing*. In the fetch stage we have only the PC — we haven't
even read the instruction yet, let alone decoded it or computed its target. So a
predictor has to answer two questions from the PC alone:

1. **Will this turn out to be a taken control transfer?** — a *direction* guess.
2. **If so, where does it go?** — a *target* guess.

Two small tables, both looked up by the low PC bits, answer those:

- **BHT (branch history table)** — an array of **2-bit saturating counters** for
  direction. The states are `00 strong-NT, 01 weak-NT, 10 weak-T, 11 strong-T`;
  the top bit is the prediction. A counter moves one step toward the outcome each
  time the branch resolves. The two-bit hysteresis is the whole point: a loop
  branch taken 50 times then not-taken once stays in a taken state through the
  single fall-through, so re-entering the loop is still predicted correctly. A
  one-bit predictor would mispredict twice per loop (the exit *and* the re-entry).

- **BTB (branch target buffer)** — a small tagged cache of `{tag, target}`. When
  a branch is taken, it records where it went. Next time that PC is fetched, the
  BTB supplies the target. No BTB entry means no known target, so we can't
  predict taken even if the counter wants to — a prediction is "taken" only on a
  **BTB hit whose counter is in a taken state**.

`rtl/branch_predictor.v` holds both. Prediction is purely combinational on the
fetch PC (it runs alongside the instruction memory read); training is a
synchronous update when a control instruction resolves in EX. Unconditional jumps
(`jal`/`jalr`) are forced to strong-taken so they're predicted from the second
encounter on.

## Folding it into the pipeline

`rtl/cpu_pipe_bp.v` is `cpu_pipe.v` with three additions:

- **Fetch redirect.** If the predictor says taken, the next PC is the BTB target
  instead of PC+4. A correctly predicted taken branch now has its target fetched
  on the very next cycle — zero bubble.
- **Carry the guess.** The prediction made for an instruction rides down the pipe
  with it (`ifid_pred_taken/target` → `idex_pred_taken/target`) so EX can check it.
- **Check in EX.** When the branch resolves we compare reality to the guess:

  ```
  dir_wrong = is_ctrl & (actual_taken != predicted_taken);
  tgt_wrong = is_ctrl & actual_taken & predicted_taken & (actual_target != predicted_target);
  mispredict = dir_wrong | tgt_wrong;
  ```

  On a mispredict we do exactly what the old core did on *every* taken branch:
  flush the two instructions behind and redirect to the correct PC (the real
  target if taken, or PC+4 if it should have fallen through). The difference is
  that this now happens only when the guess was wrong, not on every taken branch.

One subtlety worth calling out: the redirect-on-trap gate from Step 31 has a
cousin here. A wrongly-speculated instruction is at most two stages deep when the
branch resolves, so it is squashed before it can reach EX — which means anything
that *does* reach EX is on the real path and is safe to use for training and for
the performance counters. No wrong-path instruction is ever counted or commits.

## Measuring it

`make bpred` runs the *same* program on both cores and reports. The benchmark
(`sw/bpred_bench.c`) is 30×60 nested loops with a runs-of-four data-dependent
branch inside and a non-inlined helper (a real `jal`/`ret` pair), writing a
checksum and a `0x600D` sentinel when done. The testbench latches each core's
counters the moment its sentinel appears, so the final spin loop isn't counted,
and it checks that both cores compute the *same* checksum (correctness first).

A representative run:

```
 result checksum:  not-taken=0x0000e6d8   predictor=0x0000e6d8   (match)

 predict-not-taken (baseline):
   control transfers : 6183
   taken (=flushes)  : 3544
   cycles to finish  : 23068

 BTB + 2-bit predictor:
   control transfers : 6183
   taken             : 3544
   mispredictions    : 879
   misprediction rate: 14.21 %
   cycles to finish  : 17737

 mispredictions:  3544 -> 879   (2665 fewer)
 cycles:          23068 -> 17737  (1.3x, 5331 cycles saved)
```

The two cores execute the identical instruction stream (same 6183 control
transfers, 3544 taken), so the comparison is apples-to-apples. Predict-not-taken
pays a flush on all 3544 taken transfers; the predictor pays only on its 879
mispredictions. The arithmetic closes: `(3544 − 879) × 2 ≈ 5330` cycles saved,
which is exactly the measured difference. The not-taken core's "taken" count *is*
its misprediction count — that's the baseline the predictor improves on, a 4×
reduction here.

## What's verified here

`make bpred` builds the benchmark, runs both cores to completion, confirms they
produce the same result, and prints the misprediction rate and speedup. The
predictor core also passes the functional `sum` program, and the original
pipeline (`make pipe`, `make pipe-sum`) is untouched and still matches the
single-cycle reference.

## Honest status

- The 14% misprediction rate is dominated by the deliberately awkward
  data-dependent branch; loop-bound code does much better, and a branchier or
  more loop-heavy workload would show a larger speedup than 1.3×. The number to
  trust is the *reduction* (3544 → 879), which is a property of the predictor,
  not of the chosen benchmark.
- The BTB here is fully tagged (no aliasing) for clarity; real BTBs use partial
  tags and take the occasional false hit to save area. The BHT is *untagged* (as
  real ones are), so two branches that share an index alias onto one counter —
  visible only as a few extra mispredictions.
- **Returns** are predicted by the BTB's single target slot, so a function called
  from one site returns perfectly, but a function called from many sites will
  mispredict its return every time the caller changes. The standard fix is a
  **return address stack** (push on `jal`, pop on `ret`); that's the natural next
  addition and would mostly eliminate the `jalr` mispredictions.
- The predictor is verified in simulation only. It adds two small memories on the
  fetch critical path; on real silicon their access has to fit in the fetch
  cycle, which is why production BTBs are kept small and simple.
- This sits on the standalone pipelined core, which (like Step 14) has no
  CSRs/interrupts. Folding prediction into the multi-cycle FPGA core would mean
  threading the guess through its FSM instead of fixed pipe registers.

## Takeaway

A branch predictor doesn't make branches faster — it makes *guessing* cheap and
*being wrong* the only thing you pay for. Two tiny tables looked up by the PC turn
"two cycles on every taken branch" into "two cycles per misprediction", and the
2-bit counter's one idea — needing two mistakes in a row to change its mind — is
what makes loops, the branches that run the most, essentially free. Measuring it
against the not-taken baseline on the same instruction stream is what turns "I
added a predictor" into "I removed 2665 flushes and 5331 cycles."
