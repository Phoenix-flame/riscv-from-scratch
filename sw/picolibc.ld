/* =====================================================================
 * picolibc.ld  -  Linker script for bare-metal picolibc on this core
 * ---------------------------------------------------------------------
 * One RAM region at 0x0 (the program image is mirrored into both the
 * instruction ROM and the data RAM, so code and data share addresses and
 * .data needs no flash->RAM copy). Beyond _end we hand the rest of RAM to
 * picolibc: a heap (malloc, via picolibc's sbrk reading __heap_start/_end)
 * and a descending stack at the very top.
 * ===================================================================== */
ENTRY(_start)

__stack_size = DEFINED(__stack_size) ? __stack_size : 0x1000;   /* 4 KB stack */

MEMORY { RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K }

SECTIONS
{
    . = ORIGIN(RAM);

    .text : {
        *(.text.init)            /* _start must land at 0x0 */
        *(.text .text.*)
    } > RAM

    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > RAM

    . = ALIGN(8);
    PROVIDE(__global_pointer$ = . + 0x800);
    .data : {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > RAM

    .bss (NOLOAD) : {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > RAM

    . = ALIGN(16);
    _end = .;
    PROVIDE(__heap_start = .);
    PROVIDE(__heap_end   = ORIGIN(RAM) + LENGTH(RAM) - __stack_size);
    PROVIDE(__stack_top  = ORIGIN(RAM) + LENGTH(RAM));
}
