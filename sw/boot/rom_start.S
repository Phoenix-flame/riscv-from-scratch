# =====================================================================
# rom_start.S  -  boot ROM reset vector, payload entry, M-mode traps
# ---------------------------------------------------------------------
# The core resets to ROM_BASE in M-mode with everything else unknown.
# _start makes the machine sane (no interrupts, no translation, a trap
# vector that reports instead of looping), copies .data out of the ROM,
# zeroes .bss, and enters rom_main on a stack at the top of the
# firmware's RAM. It is also where the test device's reset lands.
#
# Two trap vectors. During boot, rom_panic_entry reports any trap and
# fails the run. Once a payload runs, mtvec = sbi_trap_entry: the
# resident SBI, entered from S (or U) with mscratch holding its stack.
# =====================================================================
#include "platform.h"

#define FW_STACK_TOP  (RAM_BASE + FW_RAM_SIZE)

        .section .text.init, "ax"
        .globl  _start
_start:
        csrw    mie, zero
        csrw    mstatus, zero
        la      t0, rom_panic_entry
        csrw    mtvec, t0
        csrw    medeleg, zero
        csrw    mideleg, zero
        csrw    satp, zero
        sfence.vma
        .option push
        .option norelax
        la      gp, __global_pointer$
        .option pop
        li      sp, FW_STACK_TOP

        la      t0, __data_load             # .data: ROM -> RAM
        la      t1, __data_start
        la      t2, __data_end
1:      bgeu    t1, t2, 2f
        lw      t3, 0(t0)
        sw      t3, 0(t1)
        addi    t0, t0, 4
        addi    t1, t1, 4
        j       1b
2:      la      t0, __bss_start             # .bss: zero
        la      t1, __bss_end
3:      bgeu    t0, t1, 4f
        sw      zero, 0(t0)
        addi    t0, t0, 4
        j       3b
4:      call    rom_main
        li      a0, 0x10
        j       rom_fail

# ---------------------------------------------------------------------
# enter_payload(entry, hartid, dtb, mmode): mret into the payload with
# the RISC-V boot convention -- a0 = hart ID, a1 = physical address of
# the DTB, translation off, interrupts off -- in S-mode (or M if mmode).
# Every other register is cleared so nothing of the ROM leaks through.
# ---------------------------------------------------------------------
        .text
        .globl  enter_payload
enter_payload:
        csrw    mepc, a0
        li      t0, (3 << 11) | (1 << 7)    # MPP, MPIE
        csrc    mstatus, t0
        li      t0, (1 << 11)               # MPP = S ...
        beqz    a3, 1f
        li      t0, (3 << 11)               # ... or M
1:      csrs    mstatus, t0
        la      t0, sbi_trap_entry
        csrw    mtvec, t0
        li      t0, FW_STACK_TOP
        csrw    mscratch, t0
        fence.i                             # the payload was written as data
        mv      a0, a1
        mv      a1, a2
        li      x1, 0
        li      x2, 0
        li      x3, 0
        li      x4, 0
        li      x5, 0
        li      x6, 0
        li      x7, 0
        li      x8, 0
        li      x9, 0
        li      x12, 0
        li      x13, 0
        li      x14, 0
        li      x15, 0
        li      x16, 0
        li      x17, 0
        li      x18, 0
        li      x19, 0
        li      x20, 0
        li      x21, 0
        li      x22, 0
        li      x23, 0
        li      x24, 0
        li      x25, 0
        li      x26, 0
        li      x27, 0
        li      x28, 0
        li      x29, 0
        li      x30, 0
        li      x31, 0
        mret

# ---------------------------------------------------------------------
# The SBI's trap entry. sp <-> mscratch swaps the interrupted program's
# stack for the firmware's; every register is saved in a frame that
# sbi_trap() (rom_sbi.c) reads its arguments from and writes its results
# into, then restored, and the stacks are swapped back.
# ---------------------------------------------------------------------
        .align  2
        .globl  sbi_trap_entry
sbi_trap_entry:
        csrrw   sp, mscratch, sp
        addi    sp, sp, -128
        sw      x1,   4(sp)
        sw      x3,  12(sp)
        sw      x4,  16(sp)
        sw      x5,  20(sp)
        sw      x6,  24(sp)
        sw      x7,  28(sp)
        sw      x8,  32(sp)
        sw      x9,  36(sp)
        sw      x10, 40(sp)
        sw      x11, 44(sp)
        sw      x12, 48(sp)
        sw      x13, 52(sp)
        sw      x14, 56(sp)
        sw      x15, 60(sp)
        sw      x16, 64(sp)
        sw      x17, 68(sp)
        sw      x18, 72(sp)
        sw      x19, 76(sp)
        sw      x20, 80(sp)
        sw      x21, 84(sp)
        sw      x22, 88(sp)
        sw      x23, 92(sp)
        sw      x24, 96(sp)
        sw      x25, 100(sp)
        sw      x26, 104(sp)
        sw      x27, 108(sp)
        sw      x28, 112(sp)
        sw      x29, 116(sp)
        sw      x30, 120(sp)
        sw      x31, 124(sp)
        csrr    t0, mscratch                # the interrupted sp
        sw      t0, 8(sp)
        .option push
        .option norelax
        la      gp, __global_pointer$       # the payload's gp is not ours
        .option pop
        mv      a0, sp
        call    sbi_trap
        lw      x1,   4(sp)
        lw      x3,  12(sp)
        lw      x4,  16(sp)
        lw      x5,  20(sp)
        lw      x6,  24(sp)
        lw      x7,  28(sp)
        lw      x8,  32(sp)
        lw      x9,  36(sp)
        lw      x10, 40(sp)
        lw      x11, 44(sp)
        lw      x12, 48(sp)
        lw      x13, 52(sp)
        lw      x14, 56(sp)
        lw      x15, 60(sp)
        lw      x16, 64(sp)
        lw      x17, 68(sp)
        lw      x18, 72(sp)
        lw      x19, 76(sp)
        lw      x20, 80(sp)
        lw      x21, 84(sp)
        lw      x22, 88(sp)
        lw      x23, 92(sp)
        lw      x24, 96(sp)
        lw      x25, 100(sp)
        lw      x26, 104(sp)
        lw      x27, 108(sp)
        lw      x28, 112(sp)
        lw      x29, 116(sp)
        lw      x30, 120(sp)
        lw      x31, 124(sp)
        addi    sp, sp, 128
        csrrw   sp, mscratch, sp
        mret

# ---------------------------------------------------------------------
# Any trap while the ROM itself runs is a bug: say what and where.
# ---------------------------------------------------------------------
        .align  2
        .globl  rom_panic_entry
rom_panic_entry:
        li      sp, FW_STACK_TOP
        .option push
        .option norelax
        la      gp, __global_pointer$
        .option pop
        csrr    a0, mcause
        csrr    a1, mepc
        csrr    a2, mtval
        call    rom_panic
        li      a0, 0x11
rom_fail:
        li      t0, TEST_BASE
        slli    a0, a0, 16
        li      t1, TEST_FAIL
        or      a0, a0, t1
        sw      a0, 0(t0)
5:      j       5b

# The device tree, compiled by dtc from rvfs-soc.dts.
        .section .rodata.dtb, "a"
        .balign 8
        .globl  _dtb_start, _dtb_end
_dtb_start:
        .incbin DTB_PATH
_dtb_end:
