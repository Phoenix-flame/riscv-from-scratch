# =====================================================================
# crt0.S  -  reset vector, trap vector and C runtime setup
# ---------------------------------------------------------------------
# Reset lands at address 0, which is where .text.init is linked, so the
# first instruction the core ever fetches is the one below.
#
# The trap vector is the interesting part. mtvec is set to `trap_entry`
# in DIRECT mode, so every exception and every interrupt arrives here.
# It saves the caller-saved registers (the handler is ordinary C and may
# clobber them), calls trap_handler(mcause, mepc, mtval), and uses the
# value that returns as the new mepc -- which is how the C handler skips
# over an ecall or an illegal instruction instead of re-executing it
# forever.
# =====================================================================
    .section .text.init, "ax"
    .global _start
_start:
    # gp first, and with relaxation off: the la below must not itself be
    # relaxed into a gp-relative access before gp exists.
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop

    la      sp, _stack_top
    la      t0, trap_entry
    csrw    mtvec, t0
    csrw    mstatus, zero              # start with interrupts globally off
    csrw    mie, zero

    # ---- zero .bss ----
    la      t0, _bss_start
    la      t1, _bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    li      a0, 0
    li      a1, 0
    call    main

    # main returned: report the exit code to SYSCON, which halts the core
    li      t0, 0x20000000
    sw      a0, 0(t0)
3:  j       3b

# =====================================================================
# trap_entry -- direct-mode vector for every trap
# =====================================================================
    .balign 4
    .global trap_entry
trap_entry:
    addi    sp, sp, -64
    sw      ra,  0(sp)
    sw      t0,  4(sp)
    sw      t1,  8(sp)
    sw      t2, 12(sp)
    sw      a0, 16(sp)
    sw      a1, 20(sp)
    sw      a2, 24(sp)
    sw      a3, 28(sp)
    sw      a4, 32(sp)
    sw      a5, 36(sp)
    sw      a6, 40(sp)
    sw      a7, 44(sp)
    sw      t3, 48(sp)
    sw      t4, 52(sp)
    sw      t5, 56(sp)
    sw      t6, 60(sp)

    csrr    a0, mcause
    csrr    a1, mepc
    csrr    a2, mtval
    call    trap_handler
    csrw    mepc, a0                   # the handler chooses where to resume

    lw      ra,  0(sp)
    lw      t0,  4(sp)
    lw      t1,  8(sp)
    lw      t2, 12(sp)
    lw      a0, 16(sp)
    lw      a1, 20(sp)
    lw      a2, 24(sp)
    lw      a3, 28(sp)
    lw      a4, 32(sp)
    lw      a5, 36(sp)
    lw      a6, 40(sp)
    lw      a7, 44(sp)
    lw      t3, 48(sp)
    lw      t4, 52(sp)
    lw      t5, 56(sp)
    lw      t6, 60(sp)
    addi    sp, sp, 64
    mret
