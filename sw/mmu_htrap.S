# M-mode page-fault handler for the synthesizable MMU demo. Prints "PF\n"
# over the physical UART and halts. Runs untranslated (machine mode).
        .section .text
        .globl htrap_entry
        .align 2
htrap_entry:
        li   t1, 0x10000000
1:      lw   t2, 4(t1)              # poll UART STATUS (ready bit)
        andi t2, t2, 1
        beqz t2, 1b
        li   t0, 'P'
        sb   t0, 0(t1)
2:      lw   t2, 4(t1)
        andi t2, t2, 1
        beqz t2, 2b
        li   t0, 'F'
        sb   t0, 0(t1)
3:      lw   t2, 4(t1)
        andi t2, t2, 1
        beqz t2, 3b
        li   t0, '\n'
        sb   t0, 0(t1)
        li   t1, 0x20000000         # halt
        li   t0, 1
        sw   t0, 0(t1)
4:      j    4b
