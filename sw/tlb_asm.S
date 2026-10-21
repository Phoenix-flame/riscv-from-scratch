# tlb_asm.S - Step 41: the M-mode trap handler (kernel .text) and the user
# program (.utext, linked at PA 0x1000, run at VA 0x00403000).
#
# Mailbox the testbench reads (physical RAM, written only by the kernel):
#   0x7F00 last mcause     0x7F04 last mepc
#   0x7F08 data page faults skipped    0x7F0C ecalls served
#   0x7F10 0x600D once the closing instruction page fault arrives
        .equ MBOX,    0x7F00
        .equ SAVE,    0x7E00
        .equ UART,    0x10000000
        .equ SYSCON,  0x20000000
        .equ L0_DATA, 0x3000 + 4*4             # level-0 PTE for VA 0x00404000
        .equ PTE_ALT, ((0x5000 >> 12) << 10) | 0x17   # -> PA 0x5000, V R W U

# ---------------------------------------------------------------------
# Kernel trap handler (machine mode: untranslated, never touches the TLBs)
# ---------------------------------------------------------------------
        .section .text
        .globl tlb_trap
        .align 2
tlb_trap:
        csrw mscratch, t0
        li   t0, SAVE
        sw   t1, 0(t0)
        sw   t2, 4(t0)
        sw   t3, 8(t0)
        li   t1, MBOX
        csrr t2, mcause
        sw   t2, 0(t1)
        csrr t3, mepc
        sw   t3, 4(t1)
        li   t3, 8
        beq  t2, t3, do_ecall
        li   t3, 13
        beq  t2, t3, do_dfault
        li   t3, 15
        beq  t2, t3, do_dfault

        # anything else -- the expected instruction page fault (12) -- ends
        # the run: mark it, print "IPF", halt.
        li   t3, 0x600D
        sw   t3, 16(t1)
        li   t1, UART
        li   t2, 'I'
        jal  t3, kputc
        li   t2, 'P'
        jal  t3, kputc
        li   t2, 'F'
        jal  t3, kputc
        li   t2, '\n'
        jal  t3, kputc
        li   t1, SYSCON
        sw   t2, 0(t1)
1:      j    1b

do_dfault:                                  # count it and skip the access
        lw   t3, 8(t1)
        addi t3, t3, 1
        sw   t3, 8(t1)
        j    skip

do_ecall:
        lw   t3, 12(t1)
        addi t3, t3, 1
        sw   t3, 12(t1)
        li   t3, 1
        beq  a7, t3, sys_remap
        li   t3, 2
        beq  a7, t3, sys_sfence
        j    skip
sys_remap:      # VA 0x00404000 -> PA 0x5000, deliberately WITHOUT sfence.vma
        li   t2, L0_DATA
        li   t3, PTE_ALT
        sw   t3, 0(t2)
        j    skip
sys_sfence:     # drop just the translation for the VA the user passed in a0
        sfence.vma a0, zero

skip:   csrr t3, mepc
        addi t3, t3, 4
        csrw mepc, t3
        lw   t1, 0(t0)
        lw   t2, 4(t0)
        lw   t3, 8(t0)
        csrr t0, mscratch
        mret

kputc:  # t1 = UART, t2 = char, return via t3 (clobbers t0)
        lw   t0, 4(t1)
        andi t0, t0, 1
        beqz t0, kputc
        sb   t2, 0(t1)
        jr   t3

# ---------------------------------------------------------------------
# User program. Position-independent and self-contained: it only ever
# jumps PC-relative within this page.
# ---------------------------------------------------------------------
        .section .utext, "ax"
        .align 2
        .globl user_entry
user_entry:
        li   s0, 0x00404000                 # VA_DATA  -> PA 0x4000 (for now)
        li   s2, UART                       # VA UART  -> superpage -> UART

        # -- 1: a hot loop; after the first touch every fetch and every
        #       access hits in the TLBs
        li   s1, 0
        li   t0, 100
1:      sw   t0, 8(s0)
        lw   t1, 8(s0)
        add  s1, s1, t1
        addi t0, t0, -1
        bnez t0, 1b
        sw   s1, 4(s0)                      # checksum 5050 -> PA 0x4004
        li   a0, 'T'
        jal  uputc
        li   a0, 'L'
        jal  uputc
        li   a0, 'B'
        jal  uputc
        li   a0, '\n'
        jal  uputc

        # -- 2: the code page is execute-only: reading it is a load page
        #       fault (13); the kernel counts it and skips the load
        li   t0, 0x00403000
        lw   t1, 0(t0)

        # -- 3: a PTE change is invisible until sfence.vma
        li   t2, 0x11111111
        sw   t2, 0(s0)                      # PA 0x4000
        li   a7, 1
        ecall                               # kernel: VA_DATA -> PA 0x5000
        li   t2, 0x22222222
        sw   t2, 0(s0)                      # stale D-TLB entry: still PA 0x4000
        mv   a0, s0
        li   a7, 2
        ecall                               # kernel: sfence.vma VA_DATA
        li   t2, 0x33333333
        sw   t2, 0(s0)                      # re-walked: PA 0x5000

        # -- 4: VA 0x00406000 maps the data page, readable but not
        #       executable: jumping there is an instruction page fault (12)
        li   t0, 0x00406000
        jr   t0

uputc:  lw   t3, 4(s2)                      # a0 = char
        andi t3, t3, 1
        beqz t3, uputc
        sb   a0, 0(s2)
        ret
