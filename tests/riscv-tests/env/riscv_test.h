// =====================================================================
// riscv_test.h  -  target environment for the official riscv-tests suite
// ---------------------------------------------------------------------
// riscv-tests ships the TESTS. It does not ship the ENVIRONMENT they run
// in -- upstream keeps that in a separate `riscv-test-env` repository
// (which is why `third_party/riscv-tests/env/` is an empty submodule
// directory). Every target supplies its own: the reset vector, the trap
// vector, and the mechanism a test uses to report pass/fail.
//
// This file is upstream's `p` environment ("physical memory, no virtual
// address translation") retargeted to the tutorial cores. What changed:
//
//  * `tohost` is the SYSCON halt register at 0x2000_0000 (see link.ld),
//    not a memory word polled by a host. The store that reports the
//    result is the store that stops the core.
//  * The test body runs in MACHINE mode. Upstream drops to user mode
//    after installing a PMP entry that grants U full access; these cores
//    have no PMP, and their U mode forbids every CSR access -- which the
//    F tests need for `fcsr`. The instructions under test behave
//    identically at either privilege level.
//  * No INIT_PMP (no PMP to initialise) and no CHECK_XLEN (that check
//    reports PASS on a width mismatch, and a harness must never invent a
//    pass; the build is pinned to -march=rv32* instead). The stvec_handler
//    delegation block is dropped too -- no user-level test defines one,
//    and it would need the full CAUSE_* set from upstream's encoding.h.
//
// Everything else is upstream's: INIT_XREG, the ecall-based pass/fail
// path, the trap vector, the CSR-probing init sequence. So the tests
// exercise the same machinery here that they exercise on Spike.
// =====================================================================
#ifndef _ENV_TUTORIAL_RISCV_TEST_H
#define _ENV_TUTORIAL_RISCV_TEST_H

//-----------------------------------------------------------------------
// Constants. Upstream pulls these from encoding.h; only a handful are
// reachable from the user-level suites, so they are spelled out here.
//-----------------------------------------------------------------------
#define MSTATUS_MPP            0x00001800   // previous privilege = M
#define MSTATUS_FS             0x00006000   // FP unit state = dirty

#define CAUSE_USER_ECALL       0x8
#define CAUSE_SUPERVISOR_ECALL 0x9
#define CAUSE_MACHINE_ECALL    0xb

// The suite keeps the number of the currently-running sub-test here, and
// TEST_CASE compares against it when a check fails.
#define TESTNUM gp

//-----------------------------------------------------------------------
// Per-ISA init. RVTEST_CODE_BEGIN calls `init`; each RVTEST_RV*_ macro
// below defines what that means for its ISA.
//-----------------------------------------------------------------------
#define RVTEST_ENABLE_MACHINE                                           \
  li a0, MSTATUS_MPP;                                                   \
  csrs mstatus, a0;

#define RVTEST_FP_ENABLE                                                \
  li a0, MSTATUS_FS;                                                    \
  csrs mstatus, a0;                                                     \
  csrwi fcsr, 0;

#define RVTEST_RV32U                                                    \
  .macro init;                                                          \
  RVTEST_ENABLE_MACHINE;                                                \
  .endm

#define RVTEST_RV32UF                                                   \
  .macro init;                                                          \
  RVTEST_ENABLE_MACHINE;                                                \
  RVTEST_FP_ENABLE;                                                     \
  .endm

#define RVTEST_RV32M   RVTEST_RV32U
#define RVTEST_RV64U   RVTEST_RV32U
#define RVTEST_RV64M   RVTEST_RV32U
#define RVTEST_RV64UF  RVTEST_RV32UF

//-----------------------------------------------------------------------
// Reset-vector helpers.
//-----------------------------------------------------------------------
// Start from a known architectural state rather than trusting whatever the
// register file powers up with -- these cores happen to simulate as all-zero,
// which is exactly the kind of convenience a test should not lean on.
#define INIT_XREG                                                       \
  li x1, 0;  li x2, 0;  li x3, 0;  li x4, 0;  li x5, 0;  li x6, 0;      \
  li x7, 0;  li x8, 0;  li x9, 0;  li x10, 0; li x11, 0; li x12, 0;     \
  li x13, 0; li x14, 0; li x15, 0; li x16, 0; li x17, 0; li x18, 0;     \
  li x19, 0; li x20, 0; li x21, 0; li x22, 0; li x23, 0; li x24, 0;     \
  li x25, 0; li x26, 0; li x27, 0; li x28, 0; li x29, 0; li x30, 0;     \
  li x31, 0;

#define RISCV_MULTICORE_DISABLE                                         \
  csrr a0, mhartid;                                                     \
1:bnez a0, 1b

// The next two blocks each point mtvec at their own exit label first, so
// that a core which raises an illegal-instruction trap on a CSR it does
// not implement skips the block instead of dying. (These cores read such
// CSRs as zero and swallow the write, so the guard never fires here -- but
// it costs two instructions and keeps the sequence upstream's.)
#define INIT_SATP                                                       \
  la t0, 1f;                                                            \
  csrw mtvec, t0;                                                       \
  csrwi satp, 0;                                                        \
  .align 2;                                                             \
1:

#define DELEGATE_NO_TRAPS                                               \
  la t0, 1f;                                                            \
  csrw mtvec, t0;                                                       \
  csrwi medeleg, 0;                                                     \
  csrwi mideleg, 0;                                                     \
  csrwi mie, 0;                                                         \
  .align 2;                                                             \
1:

// No interrupt source is armed, so any interrupt is a bug in the core.
#define INTERRUPT_HANDLER j other_exception

//-----------------------------------------------------------------------
// RVTEST_CODE_BEGIN  -  reset vector + trap vector, then enter the test
//-----------------------------------------------------------------------
#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .weak mtvec_handler;                                            \
        .globl _start;                                                  \
_start:                                                                 \
        /* reset vector */                                              \
        j reset_vector;                                                 \
        .align 2;                                                       \
trap_vector:                                                            \
        /* did the trap come from the pass/fail ecall? */               \
        csrr t5, mcause;                                                \
        li t6, CAUSE_USER_ECALL;                                        \
        beq t5, t6, write_tohost;                                       \
        li t6, CAUSE_SUPERVISOR_ECALL;                                  \
        beq t5, t6, write_tohost;                                       \
        li t6, CAUSE_MACHINE_ECALL;                                     \
        beq t5, t6, write_tohost;                                       \
        /* a test may install its own handler; use it if it did */      \
        la t5, mtvec_handler;                                           \
        beqz t5, 1f;                                                    \
        jr t5;                                                          \
        /* interrupt (mcause < 0) or exception? neither is expected */  \
1:      csrr t5, mcause;                                                \
        bgez t5, handle_exception;                                      \
        INTERRUPT_HANDLER;                                              \
handle_exception:                                                       \
other_exception:                                                        \
        /* unhandled trap: flag the result so it can never look like a  \
           pass, and keep the sub-test number visible in the low bits */\
        ori TESTNUM, TESTNUM, 1337;                                     \
write_tohost:                                                           \
        sw TESTNUM, tohost, t5;                                         \
        j write_tohost;                                                 \
reset_vector:                                                           \
        INIT_XREG;                                                      \
        RISCV_MULTICORE_DISABLE;                                        \
        INIT_SATP;                                                      \
        DELEGATE_NO_TRAPS;                                              \
        li TESTNUM, 0;                                                  \
        la t0, trap_vector;                                             \
        csrw mtvec, t0;                                                 \
        csrwi mstatus, 0;                                               \
        init;                                                           \
        /* enter the test body through mret, as upstream does */        \
        la t0, 1f;                                                      \
        csrw mepc, t0;                                                  \
        csrr a0, mhartid;                                               \
        mret;                                                           \
        .section .text;                                                 \
1:

//-----------------------------------------------------------------------
// Falling out of the test body is itself a failure: `unimp` traps.
//-----------------------------------------------------------------------
#define RVTEST_CODE_END                                                 \
        unimp

//-----------------------------------------------------------------------
// Pass / fail. Both routes go through ecall -> trap_vector -> tohost, so
// reporting a result exercises fence, ecall, mcause and mtvec.
//   pass -> tohost = 1
//   fail -> tohost = (failing sub-test number << 1) | 1
//-----------------------------------------------------------------------
#define RVTEST_PASS                                                     \
        fence;                                                          \
        li TESTNUM, 1;                                                  \
        li a7, 93;                                                      \
        li a0, 0;                                                       \
        ecall

#define RVTEST_FAIL                                                     \
        fence;                                                          \
1:      beqz TESTNUM, 1b;                                               \
        sll TESTNUM, TESTNUM, 1;                                        \
        or TESTNUM, TESTNUM, 1;                                         \
        li a7, 93;                                                      \
        addi a0, TESTNUM, 0;                                            \
        ecall

//-----------------------------------------------------------------------
// Test data. `tohost` is an absolute symbol from link.ld, so unlike
// upstream there is no .tohost section to emit here.
//-----------------------------------------------------------------------
#define RVTEST_DATA_BEGIN                                               \
        .align 4;                                                       \
        .global begin_signature;                                        \
begin_signature:

#define RVTEST_DATA_END                                                 \
        .align 4;                                                       \
        .global end_signature;                                          \
end_signature:

#endif
