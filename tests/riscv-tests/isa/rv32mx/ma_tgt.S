# Misaligned branch/jump targets without C (Step 58 directed test).
#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32M
RVTEST_CODE_BEGIN
  .option norvc
  # each trapping case: s0 = the faulting instruction, s1 = where to resume,
  # s2 = the target mtval must hold, t1 = 0 must stay 0 (rd not written);
  # the handler checks them and resumes

  li TESTNUM, 2                      # jal, target pc+6
  li t1, 0; la s0, 1f; la s1, 2f; addi s2, s0, 6
1: jal t1, 1b+6
  j fail
2:
  li TESTNUM, 3                      # taken beq to a misaligned target
  li t1, 0; la s0, 1f; la s1, 2f; addi s2, s0, 10
1: beq x0, x0, 1b+10
  j fail
2:
  li TESTNUM, 4                      # not-taken bne to a misaligned target: no trap
  li t2, 7
1: bne x0, x0, 1b+10
  li t2, 9
  li t3, 9
  bne t2, t3, fail
  li TESTNUM, 5                      # taken blt (compare on forwarded values)
  li t1, 0; la s0, 1f; la s1, 2f
  addi s2, s0, 6
  li a2, -5
  li a3, 3
1: blt a2, a3, 1b+6
  j fail
2:
  li TESTNUM, 6                      # jalr +2
  li t1, 0; la t0, 3f; la s0, 1f; la s1, 2f; addi s2, t0, 2
1: jalr t1, t0, 2
  j fail
3: j fail
2:
  li TESTNUM, 7                      # jalr +3 (bit 0 dropped, bit 1 set)
  li t1, 0; la t0, 3f; la s0, 1f; la s1, 2f; addi s2, t0, 2
1: jalr t1, t0, 3
  j fail
3: j fail
2:
  li TESTNUM, 8                      # jalr +1: aligned after dropping bit 0, no trap
  la t0, 1f
  jalr t1, t0, 1
  j fail
1:
  li TESTNUM, 9                      # jalr on a just-computed (forwarded) rs1
  li t1, 0; la t0, 3f; la s0, 1f; la s1, 2f
  addi t0, t0, 2
  mv s2, t0
1: jalr t1, t0, 0
  j fail
3: j fail
2:
  li TESTNUM, 10                     # jalr right after a load of rs1 (load-use)
  li t1, 0; la a4, tdat; la t0, 3f; addi t0, t0, 2; sw t0, 0(a4)
  la s0, 1f; la s1, 2f; mv s2, t0
  lw t0, 0(a4)
1: jalr t1, t0, 0
  j fail
3: j fail
2:
  li TESTNUM, 11                     # jalr where rs1 + imm carries into bit 1
  li t1, 0; la t0, 3f; addi t0, t0, 1; la s0, 1f; la s1, 2f; addi s2, t0, 1
1: jalr t1, t0, 1
  j fail
3: j fail
2:
  li TESTNUM, 12                     # ... and where the carry makes it aligned again
  la t0, 1f; addi t0, t0, -3
  jalr t1, t0, 3
  j fail
1:
  TEST_PASSFAIL

  .align 2
  .global mtvec_handler
mtvec_handler:
  li a0, 4; beq TESTNUM, a0, fail     # the no-trap cases must not get here
  li a0, 8; beq TESTNUM, a0, fail
  li a0, 12; beq TESTNUM, a0, fail
  bnez t1, fail                      # rd not written
  csrr a0, mcause; bnez a0, fail     # 0 = instruction address misaligned
  csrr a0, mepc;   bne a0, s0, fail  # epc = the branch/jump itself
  csrr a0, mtval;  bne a0, s2, fail  # tval = the misaligned target
  csrw mepc, s1
  mret

RVTEST_CODE_END
  .data
RVTEST_DATA_BEGIN
tdat: .word 0
  TEST_DATA
RVTEST_DATA_END
