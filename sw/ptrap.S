# =====================================================================
# ptrap.S  -  M-mode trap handler for the privilege demo.
#   cause  8 : ecall from USER mode  -> syscall dispatch (a7=num, a0=arg)
#   cause  2 : illegal instruction   -> user touched privileged state;
#              print a notice and skip the offending instruction
# Runs in machine mode (a trap always raises privilege to M). mret returns
# to the saved privilege (user), since mstatus.MPP was set to U on entry.
# =====================================================================
        .section .rodata
msg_blocked:
        .asciz "kernel: blocked a privileged instruction from user mode!\n"

        .section .text
        .globl ptrap_entry
        .align 2
ptrap_entry:
        addi sp, sp, -16
        sw   t0, 0(sp)
        sw   t1, 4(sp)
        sw   t2, 8(sp)
        sw   a1, 12(sp)

        csrr t0, mcause
        li   t1, 8                  # ecall from user?
        beq  t0, t1, ps_syscall
        li   t1, 2                  # illegal instruction?
        beq  t0, t1, ps_illegal
        j    ps_done

ps_syscall:
        li   t1, 1                  # SYS_PUTC
        beq  a7, t1, ps_putc
        li   t1, 2                  # SYS_EXIT
        beq  a7, t1, ps_exit
        j    ps_done
ps_putc:
        li   t1, 0x10000000
        sb   a0, 0(t1)
        j    ps_done
ps_exit:
        li   t1, 0x20000000
        sw   a0, 0(t1)              # halts the sim (never returns)

ps_illegal:
        la   a1, msg_blocked        # print the notice byte by byte
ps_il_loop:
        lbu  t2, 0(a1)
        beqz t2, ps_done
        li   t1, 0x10000000
        sb   t2, 0(t1)
        addi a1, a1, 1
        j    ps_il_loop

ps_done:
        csrr t0, mepc               # skip the trapping instruction (4 bytes)
        addi t0, t0, 4
        csrw mepc, t0
        lw   t0, 0(sp)
        lw   t1, 4(sp)
        lw   t2, 8(sp)
        lw   a1, 12(sp)
        addi sp, sp, 16
        mret                        # return to user mode (MPP=U)
