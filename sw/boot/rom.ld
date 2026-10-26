/* =====================================================================
 * rom.ld  -  the boot ROM: code in ROM, its variables in firmware RAM
 * ---------------------------------------------------------------------
 * The first program here that runs from READ-ONLY memory with writable
 * variables somewhere else, so .data has two addresses: where it is
 * stored (LMA, in the ROM image) and where the code expects it (VMA, in
 * RAM). _start copies one to the other; .bss is only ever in RAM.
 *
 *   0x0000_1000  ROM    .text, .rodata (incl. the DTB), .data's image
 *   0x8000_0000  RAM    .data, .bss -- then the stack, growing down
 *                       from 0x8000_4000 (FW_RAM_SIZE in platform.h)
 * ===================================================================== */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    ROM   (rx) : ORIGIN = 0x00001000, LENGTH = 16K
    FWRAM (rw) : ORIGIN = 0x80000000, LENGTH = 12K   /* + 4 KiB stack above */
}

SECTIONS
{
    .text : {
        *(.text.init)
        *(.text .text.*)
    } > ROM

    .rodata : {
        *(.rodata .rodata.* .srodata .srodata.*)
        . = ALIGN(4);
    } > ROM

    .data : {
        __data_start = .;
        *(.data .data.* .sdata .sdata.*)
        . = ALIGN(4);
        __data_end = .;
    } > FWRAM AT > ROM
    __data_load = LOADADDR(.data);
    PROVIDE(__global_pointer$ = __data_start + 0x800);

    .bss (NOLOAD) : {
        __bss_start = .;
        *(.sbss .sbss.* .bss .bss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > FWRAM

    __rom_end = LOADADDR(.data) + SIZEOF(.data);
    ASSERT(__rom_end <= ORIGIN(ROM) + LENGTH(ROM), "boot ROM image too large")

    /DISCARD/ : { *(.comment) *(.note*) *(.riscv.attributes) *(.eh_frame*) }
}
