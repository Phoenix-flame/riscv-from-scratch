# sched_asm.S - preemptive round-robin context switch (timer interrupt)
# Context: ctx[0]=mepc, ctx[r]=x_r (r=1..31).  mscratch holds current ctx base.
    .section .text
    .globl trap_entry
    .globl launch
    .align 2
trap_entry:
    csrrw sp, mscratch, sp          # sp = current ctx base; mscratch = task sp
    sw x1, 4(sp)
    sw x3, 12(sp)
    sw x4, 16(sp)
    sw x5, 20(sp)
    sw x6, 24(sp)
    sw x7, 28(sp)
    sw x8, 32(sp)
    sw x9, 36(sp)
    sw x10, 40(sp)
    sw x11, 44(sp)
    sw x12, 48(sp)
    sw x13, 52(sp)
    sw x14, 56(sp)
    sw x15, 60(sp)
    sw x16, 64(sp)
    sw x17, 68(sp)
    sw x18, 72(sp)
    sw x19, 76(sp)
    sw x20, 80(sp)
    sw x21, 84(sp)
    sw x22, 88(sp)
    sw x23, 92(sp)
    sw x24, 96(sp)
    sw x25, 100(sp)
    sw x26, 104(sp)
    sw x27, 108(sp)
    sw x28, 112(sp)
    sw x29, 116(sp)
    sw x30, 120(sp)
    sw x31, 124(sp)
    csrr t0, mscratch               # task's sp (x2)
    sw   t0, 8(sp)
    csrr t0, mepc                   # where the task was
    sw   t0, 0(sp)
    # --- tick accounting / stop after LIMIT ticks ---
    la   t0, ticks
    lw   t1, 0(t0)
    addi t1, t1, 1
    sw   t1, 0(t0)
    li   t2, 20
    blt  t1, t2, 1f
    li   t0, 0x20000000             # SYSCON: halt
    li   t1, 1
    sw   t1, 0(t0)
1:  # --- program the next tick: mtimecmp = mtime + INTERVAL ---
    li   t3, 0x10010000
    lw   t0, 0(t3)
    li   t1, 1200
    add  t0, t0, t1
    sw   t0, 4(t3)
    # --- round-robin: cur ^= 1; pick next ctx ---
    la   t0, cur
    lw   t1, 0(t0)
    xori t1, t1, 1
    sw   t1, 0(t0)
    la   t2, ctx0
    la   t3, ctx1
    beqz t1, 2f
    mv   sp, t3                     # next = ctx1
    j    3f
2:  mv   sp, t2                     # next = ctx0
3:  csrw mscratch, sp               # mscratch = next ctx base (for its next trap)
    lw   t0, 0(sp)                  # restore mepc
    csrw mepc, t0
    lw x1, 4(sp)
    lw x3, 12(sp)
    lw x4, 16(sp)
    lw x5, 20(sp)
    lw x6, 24(sp)
    lw x7, 28(sp)
    lw x8, 32(sp)
    lw x9, 36(sp)
    lw x10, 40(sp)
    lw x11, 44(sp)
    lw x12, 48(sp)
    lw x13, 52(sp)
    lw x14, 56(sp)
    lw x15, 60(sp)
    lw x16, 64(sp)
    lw x17, 68(sp)
    lw x18, 72(sp)
    lw x19, 76(sp)
    lw x20, 80(sp)
    lw x21, 84(sp)
    lw x22, 88(sp)
    lw x23, 92(sp)
    lw x24, 96(sp)
    lw x25, 100(sp)
    lw x26, 104(sp)
    lw x27, 108(sp)
    lw x28, 112(sp)
    lw x29, 116(sp)
    lw x30, 120(sp)
    lw x31, 124(sp)
    lw   x2, 8(sp)                  # restore task sp LAST (overwrites our base)
    mret

# launch(a0=entry, a1=stack): enter a task in user mode with interrupts on
launch:
    csrr t0, mstatus
    li   t1, ~(3 << 11)             # clear MPP -> 00 (user)
    and  t0, t0, t1
    li   t1, (1 << 7)              # MPIE=1 -> MIE=1 after mret
    or   t0, t0, t1
    csrw mstatus, t0
    csrw mepc, a0
    mv   sp, a1
    mret
