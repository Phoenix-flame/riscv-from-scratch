/* =====================================================================
 * link.ld  -  one flat image for the Spartan-6 SoC
 * ---------------------------------------------------------------------
 * Unlike the parent tutorial's Harvard cores, s6_soc has ONE unified
 * dual-port block RAM behind both the fetch port and the data port. So
 * there is a single output region: .text, .rodata, .data, .bss, the
 * stack and the heap all live in it, and the .hex the build produces is
 * the whole program.
 *
 * That also means .data needs no copy-from-ROM at startup -- the block
 * RAM is initialised with the image at configuration time. crt0 still
 * zeroes .bss, because .bss is NOLOAD and therefore not in the image.
 *
 * LENGTH below must match the MEM_WORDS parameter on s6_soc: 4096 words
 * is 16 KB. Change both together if you re-synthesise with more BRAM.
 * ===================================================================== */
OUTPUT_ARCH("riscv")
ENTRY(_start)

STACK_SIZE = 2K;

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 16K
}

SECTIONS
{
    .text : {
        KEEP(*(.text.init))          /* _start must be at address 0 */
        *(.text .text.*)
        . = ALIGN(4);
    } > RAM

    .rodata : {
        . = ALIGN(4);
        *(.rodata .rodata.* .srodata .srodata.*)
        . = ALIGN(4);
    } > RAM

    .data : {
        . = ALIGN(4);
        /* gp lets the compiler reach +/-2 KB of .sdata with one insn */
        __global_pointer$ = . + 0x800;
        *(.data .data.* .sdata .sdata.*)
        . = ALIGN(4);
    } > RAM

    .bss (NOLOAD) : {
        . = ALIGN(4);
        _bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > RAM

    . = ALIGN(16);
    _heap_start = .;
    _heap_end   = ORIGIN(RAM) + LENGTH(RAM) - STACK_SIZE;
    _stack_top  = ORIGIN(RAM) + LENGTH(RAM);
    _end        = .;

    /DISCARD/ : { *(.comment) *(.note*) *(.riscv.attributes) }
}
