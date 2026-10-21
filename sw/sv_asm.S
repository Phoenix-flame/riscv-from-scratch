# sv_asm.S - Step 44: trap handlers for M and S, the S-mode helpers, and the
# user program. See sv_demo.c for the address space.
#
# Mailbox (VA = PA 0x7F00, kernel-only), written by S unless noted:
#   +0x00 load of the user page with SUM=0 (0: it faulted)
#   +0x04 load of the user page with SUM=1
#   +0x08 S-mode load faults taken from S      +0x0C  their stval
#   +0x10 demand-paging faults served          +0x14  stval   +0x18 scause
#   +0x1C fetch fault: stval                    +0x20  sepc
#   +0x24 S->M shutdown ecalls (written by M)   +0x28  M saw anything else
#   +0x2C user ecalls served
        .equ MBOX,   0x7F00
        .equ SSAVE,  0x7E00
        .equ UART,   0x10000000
        .equ SYSCON, 0x20000000
        .equ L0_5,   0x9000 + 5*4                    # PTE for VA 0x5000
        .equ PTE_5,  ((0x5000 >> 12) << 10) | 0x17   # -> PA 0x5000, V R W U

        .section .text
# ---------------------------------------------------------------------
# M-mode: only the S kernel's shutdown call should ever arrive here.
# ---------------------------------------------------------------------
        .globl m_trap
        .align 2
m_trap:
        li   t0, MBOX
        csrr t1, mcause
        li   t2, 9
        beq  t1, t2, 1f
        sw   t1, 0x28(t0)                   # M saw a cause it should not
        j    2f
1:      lw   t2, 0x24(t0)
        addi t2, t2, 1
        sw   t2, 0x24(t0)
2:      li   t0, SYSCON                     # halt (M is untranslated)
        sw   t1, 0(t0)
3:      j    3b

# ---------------------------------------------------------------------
# S-mode trap handler (runs translated, on kernel-only pages)
# ---------------------------------------------------------------------
        .globl s_trap
        .align 2
s_trap:
        csrw sscratch, t0
        li   t0, SSAVE
        sw   t1, 0(t0)
        sw   t2, 4(t0)
        sw   t3, 8(t0)
        li   t1, MBOX
        csrr t2, scause
        li   t3, 8
        beq  t2, t3, s_ecall
        li   t3, 12
        beq  t2, t3, s_ifault
        csrr t3, sstatus                    # SPP: did the fault come from S?
        andi t3, t3, 0x100
        bnez t3, s_from_s

        # U load/store fault: demand-map VA 0x5000, else give up
        csrr t3, stval
        srli t3, t3, 12
        addi t3, t3, -5
        bnez t3, s_bad
        lw   t3, 0x10(t1)
        addi t3, t3, 1
        sw   t3, 0x10(t1)
        csrr t3, stval
        sw   t3, 0x14(t1)
        sw   t2, 0x18(t1)
        li   t2, L0_5
        li   t3, PTE_5
        sw   t3, 0(t2)                      # map the page ...
        csrr t3, stval
        sfence.vma t3, zero                 # ... drop any stale entry ...
        j    s_ret                          # ... and RETRY (sepc unchanged)

s_from_s:                                   # SUM probe: count, skip the load
        lw   t3, 0x08(t1)
        addi t3, t3, 1
        sw   t3, 0x08(t1)
        csrr t3, stval
        sw   t3, 0x0C(t1)
        j    s_skip

s_ecall:                                    # a7=1 putchar(a0), a7=2 exit
        lw   t3, 0x2C(t1)
        addi t3, t3, 1
        sw   t3, 0x2C(t1)
        li   t3, 2
        beq  a7, t3, s_shutdown
        li   t1, UART
1:      lw   t3, 4(t1)
        andi t3, t3, 1
        beqz t3, 1b
        sb   a0, 0(t1)
        j    s_skip

s_ifault:                                   # kill the task, shut down
        csrr t3, stval
        sw   t3, 0x1C(t1)
        csrr t3, sepc
        sw   t3, 0x20(t1)
        j    s_shutdown

s_bad:  sw   t2, 0x28(t1)
        .globl s_shutdown
s_shutdown:
        ecall                               # S -> M (cause 9, not delegated)
1:      j    1b

s_skip: csrr t3, sepc
        addi t3, t3, 4
        csrw sepc, t3
s_ret:  li   t0, SSAVE
        lw   t1, 0(t0)
        lw   t2, 4(t0)
        lw   t3, 8(t0)
        csrr t0, sscratch
        sret

# unsigned s_probe_user(void): load the user data page from S-mode
        .globl s_probe_user
s_probe_user:
        li   a0, 0
        li   t0, 0x4000
        lw   a0, 0(t0)                      # faults (skipped) unless SUM=1
        ret

# void s_enter_user(unsigned va): sret to U at va
        .globl s_enter_user
s_enter_user:
        li   t0, 0x100
        csrc sstatus, t0                    # SPP = U
        csrw sepc, a0
        sret

# ---------------------------------------------------------------------
# User program (.utext: PA 0x1000, runs at VA 0x3000; PC-relative only)
# ---------------------------------------------------------------------
        .section .utext, "ax"
        .align 2
        .globl user_entry
user_entry:
        li   a0, 'u'
        li   a7, 1
        ecall                               # putchar via the S kernel
        li   s0, 0x4000
        lw   t0, 0(s0)
        addi t0, t0, 1
        sw   t0, 4(s0)                      # 0x5A5A5A5B -> PA 0x4004
        li   s1, 0x5008
        li   t1, 0xD00D
        sw   t1, 0(s1)                      # unmapped: fault, S maps, retry
        lw   t2, 0(s1)
        sw   t2, 8(s0)                      # read back -> PA 0x4008
        li   a0, '!'
        li   a7, 1
        ecall
        li   t0, 0x6000
        jr   t0                             # not executable: fetch fault
