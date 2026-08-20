// =====================================================================
// boot.c  -  serial bootloader for the Spartan-6 SoC
// ---------------------------------------------------------------------
// Re-synthesising a bitstream to change one line of C takes minutes.
// This takes about a second: the block RAM is unified (the fetch port and
// the data port are two ports of the same array), so a program running
// out of it can write a *new* program into it and jump there. That is
// exactly what a store-to-instruction path buys you, and it is why this
// SoC can have a bootloader at all.
//
// Put boot.hex in the bitstream once. After that, upload programs over
// the same USB serial port you use for the console:
//
//     tools/s6load.py -p /dev/ttyUSB1 build/app.bin
//
// ---- wire protocol ------------------------------------------------------
// Host -> board:
//     'S' '6' 'L' 'D'      magic
//     u32  length          payload size in bytes, little endian
//     u32  entry           load address, and where to jump afterwards
//     ...  payload
//     u32  checksum        sum of the payload bytes, mod 2^32
//
// Board -> host, one character per event:
//     'R'  ready, magic accepted, header wanted
//     'K'  checksum matched; jumping to `entry` now
//     'E'  checksum mismatch, nothing was executed
//     'B'  the image would overrun the bootloader's own stack: refused
//
// The banner "s6boot" is printed at reset, so a host can tell a board
// sitting in the bootloader from one running an application.
// =====================================================================
#include "bsp.h"

#define BOOT_STACK_HEADROOM 1024u        // keep the top of RAM for our stack

static uint32_t get_u32(void)
{
    uint32_t v = 0;
    int i;
    for (i = 0; i < 4; i++) v |= (uint32_t)(uint8_t)uart_getc() << (8 * i);
    return v;
}

int main(void)
{
    uint32_t ram_bytes;

    uart_init(115200);
    ram_bytes = SYS_MEM_WORDS * 4;

    uart_puts("\ns6boot: waiting for an image (S6LD)\n");

    for (;;) {
        uint32_t len, entry, want, got = 0, i;
        volatile uint8_t *dst;

        // ---- resynchronise on the magic, byte by byte ----
        if (uart_getc() != 'S') continue;
        if (uart_getc() != '6') continue;
        if (uart_getc() != 'L') continue;
        if (uart_getc() != 'D') continue;
        uart_putc('R');

        len   = get_u32();
        entry = get_u32();

        // Refuse anything that would land on top of our own stack, or
        // outside the block RAM entirely -- the download would crash the
        // bootloader half way through and leave no way to report it.
        if (entry < 0x100u || (entry + len) > (ram_bytes - BOOT_STACK_HEADROOM)) {
            uart_putc('B');
            continue;
        }

        dst = (volatile uint8_t *)entry;
        for (i = 0; i < len; i++) {
            uint8_t b = (uint8_t)uart_getc();
            dst[i] = b;
            got += b;
        }
        want = get_u32();

        if (got != want) {
            uart_putc('E');
            continue;
        }

        uart_putc('K');
        uart_flush();

        // Hand over. mtvec, mie and mstatus are left as the new program
        // finds them, so its own crt0 must set them up -- which the crt0
        // in this directory does.
        csr_write(mstatus, 0);
        csr_write(mie, 0);
        ((void (*)(void))entry)();

        // if it ever returns, fall back into the download loop
        uart_puts("\ns6boot: application returned\n");
    }
}
