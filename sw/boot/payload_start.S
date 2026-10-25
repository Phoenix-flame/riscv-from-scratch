# =====================================================================
# payload_start.S  -  entry for a program the boot ROM loads into RAM
# ---------------------------------------------------------------------
# Entered in S-mode (or M) with the RISC-V boot convention: a0 = hart
# ID, a1 = physical address of the device tree, translation and
# interrupts off, every other register zero. Sets up gp and a stack of
# its own (in .bss -- the program owns no other RAM until it has read
# the DT), zeroes .bss for programs loaded by something that does not
# (the ROM already has), and calls main(hartid, dtb).
#
# When main returns, the SBI shuts the machine down: success when it
# returned 0, "system failure" otherwise.
# =====================================================================
        .section .text.init, "ax"
        .globl  _start
_start:
        mv      s0, a0
        mv      s1, a1
        .option push
        .option norelax
        la      gp, __global_pointer$
        .option pop
        la      sp, __stack_top
        la      t0, __bss_start
        la      t1, __bss_end
1:      bgeu    t0, t1, 2f
        sw      zero, 0(t0)
        addi    t0, t0, 4
        j       1b
2:      mv      a0, s0
        mv      a1, s1
        call    main
        .globl  payload_exit
payload_exit:
        snez    a1, a0                  # reason: 0 none, 1 system failure
        li      a0, 0                   # type: shutdown
        li      a6, 0
        li      a7, 0x53525354          # SBI SRST
        ecall
3:      j       3b
