/* =====================================================================
 * platform.h  -  the boot platform's memory map (rtl/soc_boot.v)
 * ---------------------------------------------------------------------
 * The ONE place these numbers are written down for software. The boot
 * ROM includes it, and so does the device tree source (dtc runs it
 * through the C preprocessor), so the DT handed to a payload cannot
 * disagree with the ROM that built it. Payloads must NOT include it:
 * everything they need to know about the machine is in the DT.
 *
 * Only preprocessor definitions here -- it is included from .dts too.
 * ===================================================================== */
#ifndef PLATFORM_H
#define PLATFORM_H

#define PLAT_CLOCK_HZ    50000000     /* nominal core clock (also mtime's) */

#define ROM_BASE         0x00001000   /* boot ROM, reset vector */
#define ROM_SIZE         0x00004000   /* 16 KiB */
#define TEST_BASE        0x00100000   /* "sifive,test0": power off / fail / reset */
#define CLINT_BASE       0x02000000   /* "sifive,clint0" */
#define PLIC_BASE        0x0c000000   /* "sifive,plic-1.0.0": contexts 0 = M, 1 = S */
#define PLIC_NDEV        31
#define UART_IRQ         10           /* the UART's PLIC source */
#define UART_BASE        0x10000000   /* "ns16550a", reg-shift 2 */
#define RAM_BASE         0x80000000   /* RAM, size found at boot */
#define RAM_WINDOW       0x10000000   /* the address window RAM may fill */

#define UART_DIVISOR     1            /* baud = clock / (16 * divisor) */

/* RAM the firmware keeps for itself: the ROM's data, its stack, and,
 * once a payload runs, the SBI's state and trap stack. The DT marks it
 * reserved (no-map), as OpenSBI does with its own image. */
#define FW_RAM_SIZE      0x00004000   /* 16 KiB at RAM_BASE */
/* The DTB handed to the payload lives in the last DTB_AREA bytes of RAM
 * (room for the fixed-up tree to grow). */
#define DTB_AREA         0x00002000   /* 8 KiB */

#define TEST_PASS        0x5555
#define TEST_FAIL        0x3333       /* | exit code << 16 */
#define TEST_RESET       0x7777

#endif
