# M-mode trap handler for the MMU demo. On a page fault (cause 13 load /
# 15 store) it prints a notice and halts. Runs in machine mode, so its
# own accesses are physical (untranslated).
        .section .rodata
msg_pf: .asciz "kernel: PAGE FAULT from user (caught by handler) -> halting\n"
        .section .text
        .globl mtrap_entry
        .align 2
mtrap_entry:
        la   a1, msg_pf
1:      lbu  t0, 0(a1)
        beqz t0, 2f
        li   t1, 0x10000000          # UART TX (physical)
        sb   t0, 0(t1)
        addi a1, a1, 1
        j    1b
2:      li   t1, 0x20000000          # SYSCON: halt the sim
        li   t0, 1
        sw   t0, 0(t1)
3:      j    3b
