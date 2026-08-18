/* =====================================================================
 * link.ld  -  linker script for the official riscv-tests suite
 * ---------------------------------------------------------------------
 * These cores are HARVARD: instructions come from a read-only ROM
 * (imem / bram_rom) and data from a separate RAM (dmem / bram_ram).
 * So the two chunks are placed in two disjoint address windows and the
 * runner splits the ELF into two images:
 *
 *   0x0000_0000 .. 0x0000_7FFF   ROM   .text.init + .text   (32 KB)
 *   0x0000_8000 .. 0x0000_FFFF   RAM   .data + .bss         (32 KB)
 *   0x2000_0000                  SYSCON halt register = `tohost`
 *
 * `tohost` is riscv-tests' result word. Pointing it at SYSCON means the
 * store that reports the result is also the store that stops the core,
 * so no polling loop and no cycle-count guessing: the testbench sees the
 * write, decodes it (1 = pass, (testnum << 1) | 1 = fail) and finishes.
 * ===================================================================== */
OUTPUT_ARCH("riscv")
ENTRY(_start)

tohost   = 0x20000000;      /* SYSCON: a write halts the core */
fromhost = 0x20000004;      /* unused here; kept for source compatibility */

MEMORY
{
    ROM (rx) : ORIGIN = 0x00000000, LENGTH = 32K
    RAM (rw) : ORIGIN = 0x00008000, LENGTH = 32K
}

SECTIONS
{
    /* ---- instruction ROM ---------------------------------------- */
    .text : {
        *(.text.init)            /* _start / trap vector must come first */
        *(.text .text.*)
    } > ROM

    /* ---- data RAM ------------------------------------------------ */
    .data : {
        . = ALIGN(16);
        *(.rodata .rodata.* .srodata .srodata.*)
        *(.data .data.* .sdata .sdata.*)
        . = ALIGN(16);
    } > RAM

    .bss (NOLOAD) : {
        . = ALIGN(16);
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(16);
    } > RAM

    _end = .;

    /DISCARD/ : { *(.comment) *(.note*) *(.riscv.attributes) }
}
