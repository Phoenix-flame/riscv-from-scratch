/* freertos.ld - layout for soc_rtos: 64KB instruction ROM (from 0), data/
 * bss/heap/stack in the 128KB data RAM. .text.init holds _start at 0x0. */
ENTRY(_start)
__stack_top = 0x0001FFF0;       /* near top of 128KB RAM */
SECTIONS
{
    . = 0x00000000;
    .text : {
        *(.text.init)
        *(.text .text.*)
    }
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
    . = ALIGN(4);
    .data : { *(.data .data.* .sdata .sdata.*) }
    . = ALIGN(4);
    __bss_start = .;
    .bss : { *(.bss .bss.* .sbss .sbss.* COMMON) }
    . = ALIGN(4);
    __bss_end = .;
    _end = .;

    /* picolibc heap (malloc/sbrk); FreeRTOS itself uses heap_4, but real libc
     * needs these bounds defined. Heap grows up from _end; stack lives at the
     * top of RAM, well above __heap_end. */
    . = ALIGN(16);
    PROVIDE(__heap_start = .);
    PROVIDE(__heap_end   = 0x0001C000);
}
