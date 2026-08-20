/* =====================================================================
 * link_app.ld  -  for programs that the serial bootloader downloads
 * ---------------------------------------------------------------------
 * Identical to link.ld except that the image starts at 0x0800 instead of
 * 0x0000, leaving the low 2 KB to boot.c. Use it when the bitstream was
 * built with boot.hex in the block RAM:
 *
 *     LDSCRIPT=sw/link_app.ld sw/build.sh sw/hello.c
 *     tools/s6load.py -p /dev/ttyUSB1 build/firmware.bin --entry 0x800
 *
 * A program built with plain link.ld starts at 0 and is meant to BE the
 * bitstream's block RAM contents; a program built with this one is meant
 * to be uploaded next to a bootloader. They are not interchangeable.
 * ===================================================================== */
OUTPUT_ARCH("riscv")
ENTRY(_start)

STACK_SIZE = 2K;

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000800, LENGTH = 14K   /* 16K - 2K bootloader */
}

SECTIONS
{
    .text : {
        KEEP(*(.text.init))
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
