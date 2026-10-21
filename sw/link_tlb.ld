/* =====================================================================
 * link_tlb.ld  -  link.ld plus a separately placed user-code page
 * ---------------------------------------------------------------------
 * The kernel (.text) starts at 0x0 as usual. User code lives in its own
 * section, .utext, at physical ROM address 0x1000 -- a page of its own,
 * so the kernel can map it at a different VIRTUAL address (it runs at
 * VA 0x00403000). Only works for position-independent code that stays
 * inside its page: PC-relative jumps/branches only, no calls out.
 * ===================================================================== */
ENTRY(_start)

SECTIONS
{
    . = 0x00000000;

    .text : {
        *(.text.init)      /* crt0 _start must come first */
        *(.text*)
    }
    ASSERT(. <= 0x1000, "kernel .text overflows into the user page at 0x1000")

    .utext 0x1000 : { *(.utext) }
    ASSERT(SIZEOF(.utext) <= 0x1000, "user code must fit in one 4 KiB page")

    .rodata : { *(.rodata*) }
    .data   : { *(.data*)   }
    .bss    : { *(.bss*) *(COMMON) }
}
