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

/* baud = clock / (16 * divisor): 1 in simulation (3.125 Mbaud, 16 clocks a
 * bit); the board build (make boot-board) passes 27 -> 115740 baud, 115200
 * within 0.5 % */
#ifndef UART_DIVISOR
#define UART_DIVISOR     1
#endif

/* RAM the firmware keeps for itself: the ROM's data, its stack, and,
 * once a payload runs, the SBI's state and trap stack. The DT marks it
 * reserved (no-map), as OpenSBI does with its own image. */
#define FW_RAM_SIZE      0x00004000   /* 16 KiB at RAM_BASE */
/* The DTB handed to the payload lives in the last DTB_AREA bytes of RAM
 * (room for the fixed-up tree to grow). */
#define DTB_AREA         0x00002000   /* 8 KiB */
/* Boot from memory (Step 56): an image something else left in RAM -- on
 * the board, the PS program copies one there from flash before it
 * releases the RISC-V. The ROM boots it, after BOOTMEM_WAIT ticks in which
 * a key on the UART gets the serial prompt instead. Only with RAM past it;
 * the image's segments must all load below it. */
#define BOOTMEM_ADDR     0x83000000   /* RAM_BASE + 48 MiB = PS DDR 0x1300_0000 */
#define BOOTMEM_WAIT     PLAT_CLOCK_HZ /* 1 s of mtime */

#define TEST_PASS        0x5555
#define TEST_FAIL        0x3333       /* | exit code << 16 */
#define TEST_RESET       0x7777

#endif
