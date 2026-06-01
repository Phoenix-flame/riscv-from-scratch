# =====================================================================
# crt0.s  -  Minimal C startup ("C runtime zero") for the bare-metal core
# ---------------------------------------------------------------------
# The CPU resets with PC=0 and every register 0 -> there is no stack and
# no entry point set up. This routine, placed at address 0, does the
# bare minimum to enter C:
#   1. set the stack pointer to the top of data memory
#   2. call main()
#   3. take main()'s return value (in a0) and store it to mem[0]
#   4. spin forever (there is no OS to return to)
# =====================================================================
        .section .text.init     # linker script places this FIRST (at 0x0)
        .globl _start
_start:
        li      sp, 0x1000       # data memory is 4096 bytes; stack grows down
        call    main             # a0 (x10) holds the int return value
        sw      a0, 0(x0)        # publish result at data memory address 0
halt:
        jal     x0, halt         # done: loop in place
