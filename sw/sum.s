# =====================================================================
# sum.s  -  Compute 1 + 2 + ... + 10 = 55, store it to memory.
# Target: RV32I, entry at address 0x0.
# =====================================================================
        .section .text
        .globl _start
_start:
        addi    x1, x0, 0          # x1 = sum     = 0  (accumulator)
        addi    x2, x0, 1          # x2 = i       = 1  (counter)
        addi    x3, x0, 11         # x3 = limit   = 11 (loop while i < 11)

loop:
        bge     x2, x3, done       # if i >= 11, exit the loop
        add     x1, x1, x2         # sum += i
        addi    x2, x2, 1          # i++
        jal     x0, loop           # unconditional jump back (rd=x0 discards)

done:
        sw      x1, 0(x0)          # mem[0] = sum (= 55)

halt:
        jal     x0, halt           # spin forever
