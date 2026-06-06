# Step 27 — Running FreeRTOS

The goal of this step was to *prepare the core* to run FreeRTOS. It turned out to
need very little new hardware — the privilege, trap, timer, and atomic work from
earlier steps had already built almost everything a real RTOS port expects — and
the result actually boots and schedules tasks.

## What FreeRTOS's RISC-V port needs, and where we stood

The standard port (`FreeRTOS-Kernel/portable/GCC/RISC-V`) runs in **machine mode
with flat memory** — no MMU. Its requirements, checked against this core:

| Requirement | Status |
|---|---|
| RV32I + Zicsr | had it (plus M and A) |
| `mstatus`/`mie`/`mip`/`mtvec`/`mepc`/`mcause`/`mscratch` | all present |
| `mhartid` readable (returns 0 on one hart) | unknown CSRs already read 0 |
| `ecall` for `portYIELD()` | present (cause 11, `mepc` set) |
| timer interrupt with `mcause` interrupt bit | present (`0x80000007`) |
| **64-bit CLINT `mtime`/`mtimecmp`** | **added (Step 1)** |
| tens of KB of ROM + RAM | **added (Step 2)** |

So the CPU and CSR/trap machinery needed *no changes*. Only two hardware gaps
existed, both addressed in the prep steps.

## The three prep steps

**Step 1 — `rtl/clint.v`.** A 64-bit CLINT-style machine timer: a free-running
`mtime` (low/high at `+0`/`+4`) and a writable `mtimecmp` (low/high at `+8`/`+C`),
with the interrupt being the level `mtime >= mtimecmp`. This is exactly what the
port's built-in `vPortSetupTimerInterrupt` drives. The instruction ROM size also
became a parameter so the RTOS SoC can hold the kernel.

**Step 2 — `rtl/soc_rtos.v`.** The same `cpu_core` (RV32IMA + Zicsr + M/U) wired
to a 64 KB instruction ROM, 128 KB data RAM, the UART, the CLINT at `0x10010000`,
and a halt register. A bare-metal smoke test (`make rtos-smoke`) confirmed the
64-bit timer + interrupt path works end-to-end through the CPU before any kernel
was involved.

**Step 3 — software scaffolding (`sw/freertos/`).**
- `FreeRTOSConfig.h` — points `configMTIME_BASE_ADDRESS`/`configMTIMECMP_BASE_ADDRESS`
  at the CLINT, sets the tick rate, heap (`heap_4`), and an ISR stack
  (`configISR_STACK_SIZE_WORDS`, so the port allocates its own).
- `start.S` + `freertos.ld` — startup that sets the stack, zeroes `.bss`,
  installs `mtvec = freertos_risc_v_trap_handler`, and calls `main`; a linker
  script laying out ROM/RAM/heap/stack for `soc_rtos`'s map.
- `shim/stdlib.h`, `shim/string.h` — this bare cross toolchain ships no libc, so
  these provide just the `size_t`/`NULL` and `mem*`/`str*` prototypes the kernel
  includes (the definitions come from `firmware.c`).
- `main.c` — a two-task demo: a producer feeds a queue, a consumer prints.

The chip hook the port requires is the stock
`chip_specific_extensions/RV32I_CLINT_no_extensions` header — our core has a CLINT
and no custom CSRs, so it fits without modification.

## Building and running

The kernel itself is third-party (MIT) and is referenced, not vendored:

```
git clone https://github.com/FreeRTOS/FreeRTOS-Kernel
make freertos FREERTOS_KERNEL=/path/to/FreeRTOS-Kernel   # compile + link -> hex
make freertos-run                                        # run on soc_rtos
```

The build links cleanly (`text ~19 KB`, `bss ~35 KB` including the 32 KB heap) and
the run produces:

```
FreeRTOS starting on RV32IMA core...
consumer got 0
consumer got 1
...
consumer got 9
FreeRTOS demo done
```

That output exercises the whole stack: `vTaskStartScheduler`, the first task
launched via `mret`, the periodic CLINT tick incrementing the scheduler and
preempting tasks, `ecall`-based yields, queue send/receive, and `vTaskDelay`.

## Honest notes and limits

- **Verified in simulation.** It builds and runs under `iverilog`; a real board
  would also need `.data` copied from ROM by the startup (here `.data` is
  preloaded into RAM) and `configCPU_CLOCK_HZ` set to the true clock so the tick
  rate is right. `configCPU_CLOCK_HZ` is set low here purely so ticks come quickly
  in simulation.
- **Flat machine mode.** The MMU (Steps 22/24) is unused — the standard port
  doesn't virtualize memory. Running tasks in user mode with per-task address
  spaces would be a much larger, non-standard effort.
- **The libc shim is minimal** — enough for this kernel configuration. Enabling
  more FreeRTOS features (software timers, stream buffers, full `printf`) may pull
  in more libc surface; a proper newlib/picolibc toolchain removes that concern.
- Atomics aren't heavily exercised by this port (it uses interrupt-disabling
  critical sections, not lock-free primitives), but they're available for
  application code.

## Takeaway

Most of "porting an RTOS" turned out to be *recognizing that the hardware was
already there*: privilege, traps, `ecall`, and a timer interrupt are the whole
contract. The genuinely new pieces were narrow — a spec-shaped 64-bit timer,
enough memory, and a few hundred lines of config/startup/linker glue. With those
in place, an unmodified FreeRTOS kernel schedules tasks on a CPU built from
scratch in this tutorial.
