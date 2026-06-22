# smode_asm.S - trap handlers and privilege-drop trampolines for the
# supervisor-delegation demo. Two handlers: m_trap (mtvec, machine) and
# s_trap (stvec, supervisor). With medeleg/mideleg set, U-mode ecalls,
# illegal instructions, and the supervisor software interrupt are vectored
# straight to s_trap; an ecall from S-mode (not delegated) reaches m_trap.
#
# The handlers must be transparent to the code they interrupt, so each parks
# one register in m/sscratch and saves the rest it uses to fixed RAM cells.
#
# RAM result cells (all written by the handlers):
#   0x400 s_ecall_cnt   0x404 s_swi_cnt    0x408 s_illegal_cnt
#   0x40C m_scall_cnt   0x410 m_bad        0x418 s_other
# handler register-save scratch: M @ 0x340.., S @ 0x350..
        .section .text
        .globl m_trap, s_trap, enter_s, enter_u
        .align 2

# ---------------- machine-mode trap handler ----------------
m_trap:
        csrw mscratch, t0              # park t0
        li   t0, 0x340
        sw   t1, 0(t0)                 # save t1
        csrr t1, mcause
        bltz t1, m_ret                 # interrupt: nothing to do, just return
        li   t0, 9
        beq  t1, t0, m_scall           # ecall-from-S (expected, NOT delegated)
        # any other exception in M, including a delegated cause that leaked
        # here, is a bug -> record it
        li   t0, 0x410
        sw   t1, 0(t0)                 # m_bad = mcause
        j    m_adv
m_scall:
        li   t0, 0x40C
        lw   t1, 0(t0)
        addi t1, t1, 1
        sw   t1, 0(t0)                 # m_scall_cnt++
m_adv:
        csrr t0, mepc                  # step over the ecall
        addi t0, t0, 4
        csrw mepc, t0
m_ret:
        li   t0, 0x340
        lw   t1, 0(t0)                 # restore t1
        csrr t0, mscratch              # restore t0
        mret

# ---------------- supervisor-mode trap handler ----------------
s_trap:
        csrw sscratch, t0              # park t0
        li   t0, 0x350
        sw   t1, 0(t0)
        sw   t2, 4(t0)
        sw   t3, 8(t0)
        csrr t1, scause
        bltz t1, s_int                 # interrupt (SSIP) -> resume, don't advance
        li   t2, 8
        beq  t1, t2, s_ecall           # ecall-from-U (delegated here)
        li   t2, 2
        beq  t1, t2, s_illegal         # illegal instruction (delegated here)
        li   t2, 0x418                 # other delegated exception -> record + skip
        sw   t1, 0(t2)
        j    s_adv
s_ecall:
        li   t2, 0x400
        lw   t3, 0(t2)
        addi t3, t3, 1
        sw   t3, 0(t2)                 # s_ecall_cnt++
        li   t2, 8                     # halt after this many ecalls (S decides)
        blt  t3, t2, 1f
        li   t2, 0x20000000            # SYSCON: halt the machine
        li   t3, 1
        sw   t3, 0(t2)
2:      j    2b
1:      li   t2, 2                     # pend a supervisor software interrupt
        csrs sip, t2                   #   (SSIP) -- delivered to S after sret
        j    s_adv
s_illegal:
        li   t2, 0x408
        lw   t3, 0(t2)
        addi t3, t3, 1
        sw   t3, 0(t2)                 # s_illegal_cnt++
        j    s_adv                     # skip the offending instruction
s_int:
        li   t2, 0x404
        lw   t3, 0(t2)
        addi t3, t3, 1
        sw   t3, 0(t2)                 # s_swi_cnt++
        li   t2, 2
        csrc sip, t2                   # clear SSIP
        j    s_ret                     # interrupt: resume interrupted instr (no +4)
s_adv:
        csrr t2, sepc
        addi t2, t2, 4
        csrw sepc, t2
s_ret:
        li   t0, 0x350
        lw   t1, 0(t0)
        lw   t2, 4(t0)
        lw   t3, 8(t0)
        csrr t0, sscratch
        sret

# ---------------- privilege-drop trampolines ----------------
# enter_s(a0=entry): from M, set MPP=S and mret into S-mode at entry.
enter_s:
        csrr t0, mstatus
        li   t1, ~(3 << 11)
        and  t0, t0, t1
        li   t1, (1 << 11)            # MPP = 01 (S)
        or   t0, t0, t1
        csrw mstatus, t0
        csrw mepc, a0
        mret

# enter_u(a0=entry): from S, set SPP=U and sret into U-mode at entry.
enter_u:
        csrr t0, sstatus
        li   t1, ~(1 << 8)            # SPP = 0 (U)
        and  t0, t0, t1
        csrw sstatus, t0
        csrw sepc, a0
        sret
