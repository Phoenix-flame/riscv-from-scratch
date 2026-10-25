// =====================================================================
// vec_vm.S  -  Step 47: vector memory operations under Sv32 translation
// ---------------------------------------------------------------------
// Runs on soc_pipe_u (tb/pipe_u_prog_tb.v, compared with
// tb/vec_vm_expected.txt). M-mode builds a page table that maps the low
// 32 KiB 4 KiB-page by 4 KiB-page -- except page 0x3000, left invalid --
// plus megapages for the UART and SYSCON, then drops to S-mode with
// paging on. The S-mode code then:
//
//   1. vle32.v of 4 words starting at 0x2ff8: elements 0 and 1 load,
//      element 2 (0x3000) takes a load page fault. The handler reports
//      mcause / mtval / vstart, maps the page, and returns to the SAME
//      instruction, which resumes at element vstart = 2.
//   2. vse32.v of the same 4 words to 0x2ff8 with the page unmapped
//      again: a store page fault at element 2; resumed the same way.
//   3. vle32ff.v (fault-only-first) with the page unmapped: no trap,
//      vl is trimmed to 2 -- the elements before the fault.
//   4. vle32ff.v whose FIRST element faults: that one does trap.
//   5. Indexed and strided loads that touch the page fault at the right
//      element, too.
//   6. A timer interrupt that comes due in the middle of 32-element vector
//      instructions: it is taken between instructions (vstart = 0), once,
//      and the results are intact.
//
// Every observed value is printed; the expected file pins them all.
// =====================================================================
    .equ UART,    0x10000000
    .equ SYSCON,  0x20000000
    .equ ROOT,    0x6000           // level-1 table
    .equ L0,      0x7000           // level-0 table for VA 0..4 MiB
    .equ PTE3,    L0 + 3*4         // the PTE for page 0x3000
    .equ LEAF,    0xCF             // V R W X A D (supervisor page)
    .equ MTIME,   0x10010000

    .section .text.init
    .globl _start
_start:
    la    sp, 0x5ff0               // (M-mode only, physical)
    la    t0, mtrap
    csrw  mtvec, t0
    li    t0, 0x200
    csrs  mstatus, t0              // mstatus.VS = Initial: vector unit on
    li    t0, MTIME
    li    t1, -1
    sw    t1, 4(t0)                // mtimecmp = never
    li    t0, 0x80
    csrs  mie, t0                  // MTIE (taken in S-mode whatever mstatus.MIE)

    // ---- page tables ----
    li    t0, ROOT
    li    t1, ((L0 >> 12) << 10) | 1
    sw    t1, 0(t0)                          // VA 0..4 MiB -> L0
    li    t1, ((UART >> 12) << 10) | 0xC7
    sw    t1, (UART >> 22)*4(t0)             // UART megapage
    li    t1, ((SYSCON >> 12) << 10) | 0xC7
    li    t2, ROOT + (SYSCON >> 22)*4
    sw    t1, 0(t2)                          // SYSCON megapage
    li    t0, L0
    li    t2, 0                              // page number
1:  slli  t1, t2, 10
    ori   t1, t1, LEAF
    sw    t1, 0(t0)
    addi  t0, t0, 4
    addi  t2, t2, 1
    li    t3, 8
    bne   t2, t3, 1b
    li    t0, PTE3
    sw    zero, 0(t0)                        // page 0x3000: not mapped

    li    t0, 0x80000000 | (ROOT >> 12)
    csrw  satp, t0
    sfence.vma
    li    t0, 0x1800
    csrc  mstatus, t0
    li    t0, 0x0800
    csrs  mstatus, t0                        // MPP = S
    la    t0, smain
    csrw  mepc, t0
    mret

// ---------------------------------------------------------------------
// S-mode, translated.
// ---------------------------------------------------------------------
smain:
    li    s0, 0x2ff8                         // straddles the page boundary
    // ---- 1. unit-stride load, fault at element 2 ----
    vsetivli t0, 4, e32, m1, ta, ma
    vmv.v.i v1, 0
    vle32.v v1, (s0)
    la    a0, s_after1
    call  puts
    vmv.x.s a0, v1
    call  puthex
    vslidedown.vi v2, v1, 3
    vmv.x.s a0, v2                           // element 3
    call  puthex
    csrr  a0, vstart
    call  puthex
    call  newline

    // ---- 2. unit-stride store, fault at element 2 ----
    li    t0, PTE3
    sw    zero, 0(t0)
    sfence.vma
    vadd.vi v3, v1, 1
    vse32.v v3, (s0)
    la    a0, s_after2
    call  puts
    lw    a0, 0(s0)
    call  puthex
    lw    a0, 12(s0)
    call  puthex
    call  newline

    // ---- 3. fault-only-first, fault at element 2 -> vl = 2 ----
    li    t0, PTE3
    sw    zero, 0(t0)
    sfence.vma
    vsetivli t0, 4, e32, m1, ta, ma
    vle32ff.v v4, (s0)
    la    a0, s_ff
    call  puts
    csrr  a0, vl
    call  puthex
    vmv.x.s a0, v4
    call  puthex
    call  newline

    // ---- 4. fault-only-first, element 0 faults -> it traps ----
    vsetivli t0, 4, e32, m1, ta, ma
    li    t0, PTE3
    sw    zero, 0(t0)
    sfence.vma
    li    t1, 0x3000
    vle32ff.v v5, (t1)
    la    a0, s_ff0
    call  puts
    csrr  a0, vl
    call  puthex
    vmv.x.s a0, v5
    call  puthex
    call  newline

    // ---- 5. strided load (stride 8 from 0x2ff0): fault at element 2;
    //         indexed load (offsets 0,4,0x10,8 from 0x2ff8): fault at 2 ----
    li    t0, PTE3
    sw    zero, 0(t0)
    sfence.vma
    li    t1, 0x2ff0
    li    t2, 8
    vlse32.v v6, (t1), t2
    li    t0, PTE3
    sw    zero, 0(t0)
    sfence.vma
    la    t1, offsets
    vle32.v v7, (t1)
    vluxei32.v v8, (s0), v7
    la    a0, s_si
    call  puts
    vslidedown.vi v9, v6, 2
    vmv.x.s a0, v9
    call  puthex
    vslidedown.vi v9, v8, 2
    vmv.x.s a0, v9
    call  puthex
    call  newline

    // ---- 6. timer interrupt during long vector instructions ----
    li    t2, 32
    vsetvli t0, t2, e32, m8, ta, ma
    li    t0, MTIME
    lw    t1, 0(t0)
    addi  t1, t1, 12
    sw    t1, 4(t0)                          // due in 12 cycles
    vid.v   v8
    vadd.vv v16, v8, v8                      // v16[i] = 2i
    vmul.vv v16, v16, v8                     // v16[i] = 2i^2
    vsetivli zero, 1, e32, m1, ta, ma
    vmv.s.x v24, zero
    vsetvli t0, t2, e32, m8, ta, ma
    vredsum.vs v24, v16, v24                 // sum 2i^2, i < 32 = 20832
    la    a0, s_irq
    call  puts
    csrr  a0, vl
    call  puthex
    vmv.x.s a0, v24
    call  puthex
    call  newline

    la    a0, s_done
    call  puts
    li    t0, SYSCON
    sw    zero, 0(t0)
1:  j     1b

// ---------------------------------------------------------------------
// M-mode trap handler: print the trap; for a page fault map page 0x3000,
// sfence and retry, for the timer interrupt push mtimecmp out.
// ---------------------------------------------------------------------
mtrap:
    csrw  mscratch, t0
    li    t0, 0x5f00                         // save area (M-mode: physical)
    sw    ra, 0(t0)
    sw    a0, 4(t0)
    sw    t1, 8(t0)
    sw    t2, 12(t0)
    sw    t3, 16(t0)
    sw    t4, 20(t0)
    sw    t5, 24(t0)
    sw    t6, 28(t0)
    la    a0, s_trap
    call  puts
    csrr  a0, mcause
    call  puthex
    csrr  a0, mtval
    call  puthex
    csrr  a0, vstart
    call  puthex
    call  newline
    csrr  t0, mcause
    bgez  t0, 2f
    li    t0, MTIME                          // interrupt: silence the timer
    li    t1, -1
    sw    t1, 4(t0)
    j     3f
2:  li    t0, PTE3                           // page fault: map the page
    li    t1, (3 << 10) | LEAF
    sw    t1, 0(t0)
    sfence.vma
3:  li    t0, 0x5f00
    lw    ra, 0(t0)
    lw    a0, 4(t0)
    lw    t1, 8(t0)
    lw    t2, 12(t0)
    lw    t3, 16(t0)
    lw    t4, 20(t0)
    lw    t5, 24(t0)
    lw    t6, 28(t0)
    csrr  t0, mscratch
    mret                                     // same mepc: resume at vstart

// ---- console (works from both modes: UART is identity-mapped) ----
putc:                                        // a0 = char
    li    t5, UART
1:  lw    t6, 4(t5)
    andi  t6, t6, 1
    beqz  t6, 1b
    sb    a0, 0(t5)
    ret
puts:                                        // a0 = string
    mv    t4, a0
    mv    t3, ra
1:  lbu   a0, 0(t4)
    beqz  a0, 2f
    call  putc
    addi  t4, t4, 1
    j     1b
2:  mv    ra, t3
    ret
puthex:                                      // a0 = value, prints " xxxxxxxx"
    mv    t4, a0
    mv    t3, ra
    li    a0, ' '
    call  putc
    li    t2, 28
1:  srl   a0, t4, t2
    andi  a0, a0, 15
    addi  a0, a0, '0'
    li    t1, '9'
    ble   a0, t1, 2f
    addi  a0, a0, 'a' - '0' - 10
2:  call  putc
    addi  t2, t2, -4
    bgez  t2, 1b
    mv    ra, t3
    ret
newline:
    mv    t3, ra
    li    a0, '\n'
    call  putc
    mv    ra, t3
    ret

s_trap:   .asciz "trap"
s_after1: .asciz "vle32 v1[0] v1[3] vstart:"
s_after2: .asciz "vse32 mem[0] mem[3]:"
s_ff:     .asciz "vle32ff vl v4[0]:"
s_ff0:    .asciz "vle32ff@0x3000 vl v5[0]:"
s_si:     .asciz "vlse32[2] vluxei32[2]:"
s_irq:    .asciz "irq: vl sum:"
s_done:   .asciz "VEC-VM: done\n"

// ---- data: 0x2ff0..0x300f ----
    .section .vdata, "aw"
    .balign 4
offsets:  .word 0, 4, 0x10, 8
    .org  0xff0
    .word 0x11111111, 0x22222222, 0xa0a0a0a0, 0xa1a1a1a1     // 0x2ff0
    .word 0xa2a2a2a2, 0xa3a3a3a3, 0xa4a4a4a4, 0xa5a5a5a5     // 0x3000
