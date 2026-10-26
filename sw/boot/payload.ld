/* =====================================================================
 * payload.ld  -  a program the boot ROM loads over the serial port
 * ---------------------------------------------------------------------
 * Linked to run from RAM, at the start of the payload area (above the
 * 16 KiB the firmware keeps for itself). The ROM loads each PT_LOAD
 * segment where this script put it and zeroes the .bss part, so there
 * is no ROM-to-RAM copy and no fixed memory size: the RAM size, like
 * everything else about the machine, comes from the device tree.
 *
 * The stack is 4 KiB of .bss; picolibc programs get a 16 KiB heap after
 * it (__heap_start / __heap_end), which the ROM does not zero.
 * ===================================================================== */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY { RAM (rwx) : ORIGIN = 0x80004000, LENGTH = 0x38000 }

SECTIONS
{
    .text : {
        *(.text.init)
        *(.text .text.*)
    } > RAM

    .rodata : {
        *(.rodata .rodata.* .srodata .srodata.*)
    } > RAM

    . = ALIGN(8);
    PROVIDE(__global_pointer$ = . + 0x800);
    .data : {
        *(.data .data.* .sdata .sdata.*)
    } > RAM

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.sbss .sbss.* .bss .bss.* COMMON)
        . = ALIGN(16);
        . += 0x1000;
        __stack_top = .;
        __bss_end = .;
    } > RAM

    _end = .;
    PROVIDE(__heap_start = ALIGN(16));
    PROVIDE(__heap_end   = __heap_start + 0x4000);

    /DISCARD/ : { *(.comment) *(.note*) *(.riscv.attributes) *(.eh_frame*) }
}
