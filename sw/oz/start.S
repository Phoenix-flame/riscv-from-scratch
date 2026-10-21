# start.S - startup and trap entry for the OpenZynq self-test (Step 45).
#
#   _start           stack, .bss, mtvec -> main(); main's return value is
#                    written to SYSCON (= halt, exit code)
#   oz_trap_entry    M-mode trap vector: full register save, C handler
#   oz_enter_lower   run fn() in U- or S-mode; returns to the caller (in M)
#                    with mcause when fn() ecalls -- or traps and the C
#                    handler decides to abort it (a setjmp/longjmp pair
#                    built from mret and the trap vector)
#   oz_s_trap        S-mode vector for the delegation test: count, ecall to M
        .section .text.init
        .globl _start
_start:
        la      sp, __stack_top
        la      t0, __bss_start
        la      t1, __bss_end
1:      bgeu    t0, t1, 2f
        sw      zero, 0(t0)
        addi    t0, t0, 4
        j       1b
2:      la      t0, oz_trap_entry
        csrw    mtvec, t0
        call    main
        li      t0, 0x20000000
        sw      a0, 0(t0)                # SYSCON: halt, exit code = a0
3:      j       3b

        .section .text
        .align  2
        .globl  oz_trap_entry
oz_trap_entry:
        csrw    mscratch, t0
        csrr    t0, mcause               # ecall from U (8) or S (9) while a
        addi    t0, t0, -8               # lower-mode run is active: return
        beqz    t0, 1f
        addi    t0, t0, -1
        bnez    t0, 2f
1:      la      t0, oz_lower_active
        lw      t0, 0(t0)
        bnez    t0, oz_lower_return
2:      csrr    t0, mscratch
        addi    sp, sp, -128
        sw      x1,  4(sp)
        sw      x3, 12(sp)
        sw      x4, 16(sp)
        sw      x5, 20(sp)
        sw      x6, 24(sp)
        sw      x7, 28(sp)
        sw      x8, 32(sp)
        sw      x9, 36(sp)
        sw      x10, 40(sp)
        sw      x11, 44(sp)
        sw      x12, 48(sp)
        sw      x13, 52(sp)
        sw      x14, 56(sp)
        sw      x15, 60(sp)
        sw      x16, 64(sp)
        sw      x17, 68(sp)
        sw      x18, 72(sp)
        sw      x19, 76(sp)
        sw      x20, 80(sp)
        sw      x21, 84(sp)
        sw      x22, 88(sp)
        sw      x23, 92(sp)
        sw      x24, 96(sp)
        sw      x25, 100(sp)
        sw      x26, 104(sp)
        sw      x27, 108(sp)
        sw      x28, 112(sp)
        sw      x29, 116(sp)
        sw      x30, 120(sp)
        sw      x31, 124(sp)
        call    oz_trap                  # a0 != 0: abort the lower-mode run
        bnez    a0, oz_lower_return
        lw      x1,  4(sp)
        lw      x3, 12(sp)
        lw      x4, 16(sp)
        lw      x5, 20(sp)
        lw      x6, 24(sp)
        lw      x7, 28(sp)
        lw      x8, 32(sp)
        lw      x9, 36(sp)
        lw      x10, 40(sp)
        lw      x11, 44(sp)
        lw      x12, 48(sp)
        lw      x13, 52(sp)
        lw      x14, 56(sp)
        lw      x15, 60(sp)
        lw      x16, 64(sp)
        lw      x17, 68(sp)
        lw      x18, 72(sp)
        lw      x19, 76(sp)
        lw      x20, 80(sp)
        lw      x21, 84(sp)
        lw      x22, 88(sp)
        lw      x23, 92(sp)
        lw      x24, 96(sp)
        lw      x25, 100(sp)
        lw      x26, 104(sp)
        lw      x27, 108(sp)
        lw      x28, 112(sp)
        lw      x29, 116(sp)
        lw      x30, 120(sp)
        lw      x31, 124(sp)
        addi    sp, sp, 128
        mret

# unsigned oz_enter_lower(void (*fn)(void), unsigned mode /* 0 U, 1 S */)
        .globl  oz_enter_lower
oz_enter_lower:
        la      t0, oz_ctx
        sw      ra,  0(t0)
        sw      sp,  4(t0)
        sw      s0,  8(t0)
        sw      s1, 12(t0)
        sw      s2, 16(t0)
        sw      s3, 20(t0)
        sw      s4, 24(t0)
        sw      s5, 28(t0)
        sw      s6, 32(t0)
        sw      s7, 36(t0)
        sw      s8, 40(t0)
        sw      s9, 44(t0)
        sw      s10, 48(t0)
        sw      s11, 52(t0)
        li      t1, 1
        la      t2, oz_lower_active
        sw      t1, 0(t2)
        csrw    mepc, a0
        csrr    t1, mstatus
        li      t2, ~(3 << 11)
        and     t1, t1, t2
        slli    a1, a1, 11
        or      t1, t1, a1               # MPP = mode
        csrw    mstatus, t1
        addi    sp, sp, -256             # the lower mode's stack, below ours
        mret

oz_lower_return:
        la      t0, oz_lower_active
        sw      zero, 0(t0)
        la      t0, oz_ctx
        lw      ra,  0(t0)
        lw      sp,  4(t0)
        lw      s0,  8(t0)
        lw      s1, 12(t0)
        lw      s2, 16(t0)
        lw      s3, 20(t0)
        lw      s4, 24(t0)
        lw      s5, 28(t0)
        lw      s6, 32(t0)
        lw      s7, 36(t0)
        lw      s8, 40(t0)
        lw      s9, 44(t0)
        lw      s10, 48(t0)
        lw      s11, 52(t0)
        csrr    a0, mcause
        ret

# S-mode vector for the delegation test
        .align  2
        .globl  oz_s_trap
oz_s_trap:
        la      t0, oz_s_hits
        lw      t1, 0(t0)
        addi    t1, t1, 1
        sw      t1, 0(t0)
        csrr    t1, scause
        la      t0, oz_s_cause
        sw      t1, 0(t0)
        ecall                            # S -> M (cause 9): back to the test
