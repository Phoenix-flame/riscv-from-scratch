.section .text.init
.globl _start
_start:
    li   sp, 0x1000
    la   t0, teh
    csrw mtvec, t0
    ecall                 # M-mode ecall (cause 11) -> handler prints 'E'
    li   t1, 0x10000000   # then main prints 'K'
    li   t0, 'K'
    sb   t0, 0(t1)
    li   t1, 0x20000000   # halt
    li   t0, 1
    sw   t0, 0(t1)
1:  j 1b
.align 2
teh:
    li   t1, 0x10000000
    li   t0, 'E'
    sb   t0, 0(t1)
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret
