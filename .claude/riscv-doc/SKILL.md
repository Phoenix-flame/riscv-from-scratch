---
name: riscv-doc
description: >
  Use this skill whenever the user needs to write or update a tutorial step
  document for the RISC-V CPU project — specifically the markdown files in
  docs/NN-name.md. Triggers on: "write the doc for step N", "document this
  step", "add to the tutorial", "write up what we built", or any request to
  produce a docs/ file describing what was just implemented. Also triggers when
  the user asks to update the README roadmap table or the future-directions list,
  or wants to describe a hardware concept (pipeline stages, branch prediction,
  the PLIC, RVC fetch) in the tutorial's established voice.
---

# RISC-V Tutorial Doc Skill

Each step in `docs/NN-name.md` is a self-contained technical article. The tone
is precise but readable — the kind of explanation you'd want when returning to a
piece of hardware six months later. It's not a reference manual and not a
tutorial hand-hold; it's a working engineer's record of what was built, why, and
what the non-obvious parts are.

## House style

**Prose, not bullets.** Write in paragraphs. Don't use bullet lists for body
content — use them only for compact reference tables or register maps where
rows/columns are the natural structure. Never use bold for routine emphasis;
bold is for things genuinely critical (a gotcha, a constraint) used sparingly.

**No "In this step we will..." preambles.** Open in medias res: state the
problem the new hardware solves, or the thing that was invisible before that
is now worth naming.

**Explain the why.** When describing a design choice, say why that choice was
made rather than the alternatives. The register-file isn't 3-ported "because
that's how CPUs work"; it's 3-ported because a 3-operand instruction (two
sources plus one destination) needs two simultaneous reads in the decode stage.

**Honest about limitations.** Every step ends with an "Honest status" section
that clearly separates what is simulation-verified from what is synthesis-proven
or formally-verified. Don't oversell.

## Mandatory section structure

Every `docs/NN-name.md` must have these sections, in this order:

```markdown
# Step NN — Title

[1–3 paragraph introduction: what problem this solves, and what was invisible
or missing before that this step makes explicit.]

## [Conceptual heading: the main mechanism or design idea]

[Explain how it works. For hardware, describe the datapath first (what signals
exist, how they flow), then control (how the FSM or combinational logic drives
them). For peripheral protocols, describe the register interface before the
timing.]

## [Second major section: the implementation detail that's non-obvious]

[This is where you describe the hard part: the timing constraint, the edge
case in the protocol, the bus hazard, the state that has to be preserved
across a straddle. If there was a bug found during verification, describe it
here — what the symptom was, what caused it, and what the fix is. A diagnosed
bug is more educational than code that "just worked".]

## What the [demo/test/benchmark] shows

[Describe what `make <target>` does and what the output means. If there are
numbers (cycle counts, misprediction rates, code sizes), explain why they are
what they are — does the arithmetic close?]

## What's verified here

[A brief, specific list of what the testbench actually checks. Not "everything
works" but "the testbench verifies X and Y, and asserts Z is nonzero."]

## Honest status

[What is and isn't proven. Template:]
- Verified in simulation only.
- [Specific limitations: no edge-mode gateway, no multi-hart, etc.]
- [Synthesis note if relevant.]
- [What the natural follow-up / next step would be.]

## Takeaway

[1–3 sentence summary of the core insight. What did building this teach?
This should be something you could quote out of context and still be interesting.]
```

## Writing the introduction

The first paragraph frames the problem. Good intros:
- Describe what the system *couldn't* do before this step, and why that mattered.
- Name the mechanism that fixes it in the first sentence.
- Don't say "In this step we add X." Just describe X and why it exists.

Example (from Step 33 — PLIC):
> Up to now "external interrupt" meant a single wire. Step 31 ran the UART's
> interrupt straight into the core's MEIP. That works for one device, but as
> soon as there are several — a UART, a timer-capture line, a couple of GPIOs —
> they all have to share that one bit. ORing them together tells the core *an*
> interrupt happened but not *which*...

## Writing the honest status section

Be specific. Vague honesty ("this hasn't been tested on real hardware") is less
useful than specific honesty:

Good:
> The gateway is the simple level/pulse hybrid described above; it does not
> implement the spec's separate edge-vs-level configuration per source.
> The claim's read-side-effect correctness depends on the new `dmem_re` strobe.
> Any future peripheral with a side-effecting read must qualify on it too.

Not good:
> This is a simplified implementation. A real PLIC would have more features.

## Writing the takeaway

Three criteria: (1) it should state the *insight*, not the feature ("A branch
predictor doesn't make branches faster — it makes *guessing* cheap"); (2) it
should be grounded in the specific numbers or mechanisms of this step; (3) it
should close the loop on whatever gap the introduction described.

## Inline code and signal names

- RTL signal/module names in backticks: `` `dmem_re` ``, `` `cpu_mc` ``, `` `S_EXEC` ``
- Register names in small-caps or backtick: `mtvec`, `mepc`, `MEIP`
- Hex constants: `0x1002_3004`, `0x600D`
- Verilog excerpts: use fenced code blocks with the language tag omitted (plain triple-backtick)

## Register maps

Use a compact table, not prose:
```markdown
| Offset | Name | Access | Description |
|---|---|---|---|
| 0x0000 + 4*i | priority[i] | RW | Source i priority (0 = masked) |
| 0x1000 | pending | RO | Bitmap: bit i = source i pending |
```

## README updates

After every new step, update two places in README.md:

**Roadmap table** (add a new row at the end):
```markdown
| NN | `docs/NN-name.md` | One-sentence description | **done & tested (sim)** |
```

**Future directions list** — find the matching item (marked 🟢) and change it:
```
🟢 **Feature name** — brief spec    ->    ✅ **Feature name** — what was built (Step NN): key number or result. Natural follow-up noted.
```

If there's no existing future-directions item for a new step, add one under the
appropriate heading as ✅ from the start.

## What to include in "What the test shows"

Always explain the numbers if they appear:
- Cycle counts: does the arithmetic close? (e.g., "3544 − 879 mispredictions
  × 2-cycle penalty ≈ 5330 cycles saved, which is exactly the measured
  difference")
- Code sizes: what's the source of the savings?
- Claim orders: why this order? (priority values, tiebreak rule)

If the test compares two runs (baseline vs optimised), make the comparison table
explicit:

```markdown
| | predict-not-taken | BTB + 2-bit |
|---|---|---|
| control transfers | 6183 | 6183 |
| taken / mispredicts | 3544 flushes | 879 mispredicts (14.2%) |
| cycles | 23068 | 17737 |
```

## Things to avoid

- "As mentioned above" / "As we saw" — the doc should be readable without
  memorising earlier sections.
- Listing every signal in a module as prose ("the module has inputs clk, rst,
  sel, we, addr..."). Link to the source file or use a register table instead.
- Passive voice for design choices ("it was decided to..."). Use active:
  "We gate the select on `dvalid` rather than the raw address because..."
- Restating the problem after already solving it. State the problem, state the
  solution, explain why the solution works. Don't circle back.
