# =====================================================================
# trap_handler.S  -  Machine-mode trap handler with a tiny syscall ABI.
# ---------------------------------------------------------------------
# Convention (like Linux RISC-V): syscall number in a7, argument in a0.
#   a7 = 1  SYS_PUTC : print the byte in a0 to the UART
#   a7 = 2  SYS_EXIT : halt the simulation with code a0
# After handling an ecall we advance mepc past the ecall (it is 4 bytes)
# so mret returns to the instruction *after* the ecall.
#
# The handler preserves the temporaries it uses (t0,t1) on the stack so
# it does not disturb the interrupted code. a0/a7 are read directly --
# they still hold the caller's values at trap time.
# =====================================================================
        .section .text
        .globl trap_entry
        .align 2                     # mtvec base must be 4-byte aligned
trap_entry:
        addi    sp, sp, -16
        sw      t0, 0(sp)
        sw      t1, 4(sp)

        csrr    t0, mcause
        li      t1, 11               # ecall from M-mode
        bne     t0, t1, trap_done    # (other causes: just return, demo-only)

        li      t1, 1                # SYS_PUTC ?
        beq     a7, t1, sys_putc
        li      t1, 2                # SYS_EXIT ?
        beq     a7, t1, sys_exit
        j       trap_done

sys_putc:
        li      t1, 0x10000000       # UART_TX
        sb      a0, 0(t1)
        j       trap_done

sys_exit:
        li      t1, 0x20000000       # SYSCON (halts the simulation)
        sw      a0, 0(t1)
        # (never returns)

trap_done:
        csrr    t0, mepc             # advance past the ecall (4 bytes)
        addi    t0, t0, 4
        csrw    mepc, t0
        lw      t0, 0(sp)
        lw      t1, 4(sp)
        addi    sp, sp, 16
        mret
