# Step 35 — The F extension: a single-precision FPU, the float register file, and `fcsr`

Every arithmetic instruction so far has operated on the same 32-bit integers,
and the one register file held all the state the machine had. Floating point
breaks both assumptions at once. It adds a *second* register file — `f0`–`f31`,
living entirely apart from `x0`–`x31` — and a datapath that interprets those
bits as sign, exponent, and fraction rather than as a two's-complement integer.
It also adds a small amount of mode and status state, `fcsr`, that no integer
instruction ever touches. This step builds the single-precision (F) extension:
the float register file, the FPU behind it, the control-and-status register
that configures rounding and records exceptions, and the load/store and decode
work in the core that ties them together. The result runs real
`-march=rv32imf` code emitted by gcc and produces results bit-identical to the
host's hardware float.

## Two register files, and why floating point needs its own

The cleanest way to see why F is more than "more ALU ops" is the register file.
A float and an integer of the same width are different *kinds* of value: the
bit pattern `0x40490FDB` is the integer 1,078,530,011 or the float 3.14159
depending only on which unit reads it. Keeping them in one file would force
every instruction to declare which interpretation it wanted on every port, and
would make a 3-operand fused multiply-add compete with integer code for the
same read ports. RISC-V instead gives floating point its own file. `fregfile.v`
is almost the same Verilog as the integer `regfile` — two combinational read
ports, one synchronous write port — with one deliberate difference: there is no
hardwired-zero register. `x0` reads as zero because so much integer code wants a
free zero; floating-point code does not, so `f0` is an ordinary read/write
register and a floating-point zero is something you *make* (with `fmv.w.x` from
`x0`, or `fcvt.s.w`). The core therefore carries two `rs1`/`rs2` read results
side by side, and each instruction picks which file it means.

Most FP instructions read and write the float file. A handful cross the
boundary: `fcvt.s.w` and `fmv.w.x` read an *integer* source and write a float;
`fcvt.w.s`, `fmv.x.w`, `fclass`, and the compares (`feq`/`flt`/`fle`) read
floats and write an *integer* destination. The FPU signals which side its
result belongs on with a single `to_int` line, and the core routes the
write-back to the integer or the float file accordingly. Operand routing is the
mirror image: only `fcvt.s.w[u]` and `fmv.w.x` take `rs1` from the integer file;
everything else reads the float file.

## Inside the FPU: unpack, operate, round

`fpu_f.v` is where the bit pattern becomes a number. A single-precision float is
a sign bit, an 8-bit biased exponent, and a 23-bit fraction with an implied
leading one, so the first thing the unit does is unpack each operand into a sign,
a true 24-bit significand (the hidden bit made explicit), and a set of class
flags — is this a zero, an infinity, a NaN, a signalling NaN? Those classes
dominate the special-case logic: infinity minus infinity is an invalid
operation that must produce a quiet NaN and raise the NV flag; infinity times
zero is likewise invalid; a NaN on either input propagates a canonical quiet NaN
on the output. Getting these right is most of what separates a real FPU from a
mantissa multiplier.

The arithmetic itself is conventional. Addition aligns the smaller operand's
significand to the larger exponent, shifting the bits that fall off the bottom
into a sticky bit, then adds or subtracts depending on the signs; a subtraction
that cancels leading bits is renormalized with a leading-zero count.
Multiplication multiplies the two 24-bit significands into a 48-bit product, adds
the exponents, and normalizes the one-bit ambiguity (the product of two values
in [1, 2) lands in [1, 4), so the leading one is in one of two places). Division
and square root are genuinely iterative: division does a restoring long division
of the significands to produce a quotient plus a remainder, and square root runs
an integer-sqrt recurrence over the mantissa scaled up by enough bits to carry
the result's precision. All four feed the same back end.

That shared back end is the rounder, and it is the part most worth describing,
because rounding — not the arithmetic — is where floating point earns its
reputation. Every operation produces more bits than fit in the 23-bit fraction,
and the bits below the cut are summarized into three: a *guard* bit (the first
discarded bit), a *round* bit (the next), and a *sticky* bit (the OR of
everything below that). Those three, plus the parity of the last kept bit, are
exactly enough to round correctly in any mode. The default, round-to-nearest
ties-to-even, increments when the discarded part is more than half a unit, or
exactly half and the kept bit is odd. The four directed modes — toward zero,
down, up, and ties-to-max-magnitude — each have their own one-line condition over
the same three bits. The rounder also owns the exponent endgame: a round that
carries out of the significand bumps the exponent, an exponent that runs past the
top of the range becomes infinity (or the largest finite value, in the directed
modes that round away from infinity), and the inexact, overflow, and underflow
flags are set here where the information actually exists.

## `fcsr`: rounding mode in, exception flags out

The one piece of state that is neither operand nor result is `fcsr`. It holds
two things: `frm`, the dynamic rounding mode, and `fflags`, five sticky bits
that accumulate the exceptions every operation has raised since software last
cleared them. The RISC-V encoding maps three CSR addresses onto the same
register — `0x001` reads/writes just `fflags`, `0x002` just `frm`, and `0x003`
the combined `fcsr` — so the core intercepts those three addresses and handles
them locally rather than in the shared `csr.v`, which knows nothing about
floating point. Each arithmetic instruction carries a 3-bit rounding-mode field;
the value `111` means "use the dynamic mode," so the core resolves that to
`frm` before handing the mode to the rounder. After every FP operation the
core ORs the operation's exception flags into `fflags`. The accumulation is the
whole point: software runs a block of floating-point code and then reads
`fflags` once to ask "did anything inexact, or overflow, or divide by zero
happen anywhere in there?"

## Sequencing the FPU into a multi-cycle core

The integer core retires most instructions in two cycles and loads in three. The
FPU does not fit that mould — division and square root take many cycles — so the
core gains one state, `S_FPU`. An OP-FP instruction starts the FPU in its EXEC
cycle and then parks in `S_FPU`, holding the PC, until the unit asserts `done`;
the write-back and the `fflags` accrual happen on that cycle, and only then does
the PC advance. The add/sub/multiply/convert/compare ops still finish quickly;
the wait state simply absorbs whatever latency the operation needs without the
rest of the core having to know which operation it was.

Loads and stores need no new state. `flw` and `fsw` compute their address with
the integer ALU path (`rs1` plus the immediate, exactly like integer load/store)
and use the existing data bus — `flw` walks through the same `S_MEM` cycle an
integer load does, but writes its result to the float file; `fsw` reads the
float file for its store data. The only decode subtlety is the immediate type:
`fsw` is an S-type store and `flw` an I-type load, and since the shared control
unit doesn't recognize the FP opcodes, the core selects the immediate form
locally. Everything else about the bus — byte enables, the registered read, the
`dmem_re` strobe that keeps peripherals from mistaking an address match for a
real access — is inherited unchanged.

All of the FP decode lives in `cpu_mc_f.v`, not in `control.v`. This is the same
discipline the compressed-instruction core followed: a new feature that only one
core needs is decoded in that core, so the shared integer control unit — and
every other core and SoC built on it — stays exactly as it was, and the
regression proves it.

## Where this FPU stops, on purpose

Two simplifications are worth stating plainly because they are real engineering
choices, not bugs. First, subnormals — the tiny values below the smallest normal
float, where the implied leading one becomes a leading zero — are flushed to zero
on both input and output. This "flush-to-zero / denormals-are-zero" behaviour is
what many embedded and GPU FPUs actually do, because handling subnormals
correctly costs significant hardware for values almost no program depends on. The
consequence is precise and worth being precise about: every result in the entire
*normal* range is bit-identical to a host float32, and the only values that
differ are in the narrow band within about 10⁻³⁸ of zero, which flush to zero
instead of going subnormal. Second, the fused multiply-add family
(`fmadd`/`fmsub`/`fnmadd`/`fnmsub`) and double precision (D) are not implemented.
FMA's defining feature is that it rounds *once*, after the multiply and the add,
which needs a wider internal product and its own rounding path; D doubles every
datapath width and adds NaN-boxing of single values in the 64-bit registers.
Both are natural next steps that reuse the rounder and the register-file plumbing
built here.

## What the demo shows

`make fp` compiles `sw/fp_demo.c` with `-march=rv32imf -mabi=ilp32f` — so gcc
passes floats in float registers and emits genuine `flw`, `fsw`, `fadd.s`,
`fsub.s`, `fmul.s`, `fdiv.s`, `fsqrt.s`, `fcvt`, `fmv`, and compare instructions,
with the float literals placed in `.rodata` and loaded by `flw` — and runs it on
`soc_f`. The program performs fifteen operations spanning all of those
instruction forms, writes each result to a fixed RAM address as raw float bits,
and halts through SYSCON. The testbench then checks all fifteen against values
the host computed in float32. They match exactly, including the cases chosen to
be interesting: `0.1f + 0.2f` lands on `0x3E99999A` (not `0.3`), `sqrtf(2)` on
`0x3FB504F3`, and `(int)3.9f` truncates to 3 through `fcvt.w.s`.

`make fpu-unit` is the more searching test. It drives the FPU datapath directly
with 340 random operands across add, subtract, multiply, divide, square root, and
both conversion directions, each checked bit-for-bit against the host's float32
result, plus 27 directed vectors covering the special values the random set
won't reach — infinity arithmetic, signed zeros, quiet and signalling NaNs, the
sign-injection ops, min/max with a NaN operand, the three compares with NaN and
with `+0 == -0`, and every `fclass` category. All 367 pass.

## What's verified here

The standalone unit test checks the FPU's arithmetic against a host float32
reference at 367 points — 340 random normal-range operands across all five
arithmetic ops and both conversions, 27 directed special-value and exact-op
vectors — with bit-exact comparison. The integration test confirms the whole
path: gcc-emitted FP instructions, the two register files, operand and result
routing across the integer/float boundary, the flw/fsw data path, the `S_FPU`
wait state, and `fcsr`, all exercised by a real compiled program whose fifteen
results match the host. The full regression confirms the new core disturbed
nothing: `cpu_mc_f` is a separate core, `control.v` and `csr.v` are byte-for-byte
unchanged, and every prior testbench still passes.

## Honest status

- Subnormals are flushed to zero (FTZ/DAZ). Normal-range results are bit-exact
  against the host; the denormal band near zero is not modelled. This is a
  documented design choice, but it is a deviation from a fully IEEE-754-compliant
  FPU, which would represent subnormals.
- FMA (`fmadd`/`fmsub`/`fnmadd`/`fnmsub`) and double precision (D) are not
  implemented. The decode space and the register-file read port for a third
  operand are the missing pieces for FMA; D is a width change plus NaN-boxing.
- Divide and square root are modelled with a fixed multi-cycle latency around a
  combinational recurrence. That is correct and timed in simulation, but a
  synthesizable build needs a true iterative datapath that does one recurrence
  step per cycle; the cycle count is honest, the per-cycle logic depth is not yet
  what hardware would use.
- Rounding is fully implemented for all five modes, but the directed (non-RNE)
  modes are exercised far less than round-to-nearest by these tests; the
  rigorous upgrade is a riscv-arch-test style compliance suite that sweeps every
  mode against every operation.
- Verified in simulation only.

## Takeaway

Floating point looks like an arithmetic feature and is really a *representation*
feature. The multiplier and adder at its core are ordinary; what makes an FPU an
FPU is everything around them — a second register file because floats and
integers are different kinds of value, a rounder that turns the extra bits every
operation generates into a correctly-rounded result, a status register that
remembers which exceptions happened, and a fistful of special cases so that
infinities and NaNs behave the way the standard demands. Build those, and gcc's
`-march=rv32imf` output runs and agrees with the host down to the last bit —
except in the denormal band we deliberately chose to flush, which is the one
place the honest accounting and the IEEE standard part ways.
