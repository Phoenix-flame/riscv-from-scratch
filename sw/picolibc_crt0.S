# =====================================================================
# picolibc_crt0.S  -  C startup for bare-metal picolibc
# ---------------------------------------------------------------------
# Sets the global pointer (gp) so picolibc's small-data accesses work,
# points sp at the top of RAM, zeroes .bss (picolibc's malloc and stdio
# assume zeroed BSS, unlike the old hand-rolled crt0), then calls main().
# When main returns we write SYSCON to halt the core.
# =====================================================================
        .section .text.init
        .globl _start
_start:
        .option push
        .option norelax
        la      gp, __global_pointer$
        .option pop
        la      sp, __stack_top

        # zero .bss
        la      t0, __bss_start
        la      t1, __bss_end
1:      bgeu    t0, t1, 2f
        sw      zero, 0(t0)
        addi    t0, t0, 4
        j       1b
2:
        call    main
        # publish return code at mem[0] (matches the project convention) and halt
        sw      a0, 0(zero)
        li      t0, 0x20000000
        li      t1, 1
        sw      t1, 0(t0)
3:      j       3b
