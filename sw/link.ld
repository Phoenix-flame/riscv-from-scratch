/* =====================================================================
 * link.ld  -  Linker script for the bare-metal RV32I core
 * ---------------------------------------------------------------------
 * Places code starting at address 0x0 (where the PC resets), with the
 * startup section .text.init first so _start sits exactly at 0x0.
 * Data/bss are given addresses too, but this core's programs keep all
 * runtime data on the stack, so those sections stay empty.
 * ===================================================================== */
ENTRY(_start)

SECTIONS
{
    . = 0x00000000;

    .text : {
        *(.text.init)      /* crt0 _start must come first */
        *(.text*)
    }

    .rodata : { *(.rodata*) }
    .data   : { *(.data*)   }
    .bss    : { *(.bss*) *(COMMON) }
}
