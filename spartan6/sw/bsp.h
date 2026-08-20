// =====================================================================
// bsp.h  -  board support for the Spartan-6 SoC (s6_soc)
// ---------------------------------------------------------------------
// The memory map, the peripheral registers, and a small runtime: UART
// I/O, a printf subset, microsecond delays off the CLINT, and the CSR
// accessors. No libc, no malloc -- everything here fits in a few hundred
// instructions so a 16 KB block RAM still has room for a real program.
// =====================================================================
#ifndef S6_BSP_H
#define S6_BSP_H

#include <stdint.h>
#include <stddef.h>

#define REG32(a) (*(volatile uint32_t *)(a))

// ---- memory map -----------------------------------------------------
#define UART_BASE   0x10000000u
#define CLINT_BASE  0x10010000u
#define GPIO_BASE   0x10020000u
#define SYSCON_BASE 0x20000000u
#define SRAM_BASE   0x40000000u

// ---- UART -----------------------------------------------------------
#define UART_RXTX    REG32(UART_BASE + 0x00)
#define UART_STATUS  REG32(UART_BASE + 0x04)
#define UART_CTRL    REG32(UART_BASE + 0x08)
#define UART_BAUD    REG32(UART_BASE + 0x0C)
#define UART_IE      REG32(UART_BASE + 0x10)
#define UART_IP      REG32(UART_BASE + 0x14)
#define UART_LEVEL   REG32(UART_BASE + 0x18)
#define UART_WMARK   REG32(UART_BASE + 0x1C)
#define UART_IDLECFG REG32(UART_BASE + 0x20)

#define UART_ST_TXEMPTY  (1u << 0)
#define UART_ST_TXFULL   (1u << 1)
#define UART_ST_TXBUSY   (1u << 2)
#define UART_ST_RXEMPTY  (1u << 3)
#define UART_ST_RXFULL   (1u << 4)
#define UART_ST_OVERRUN  (1u << 5)
#define UART_ST_FRAMEERR (1u << 6)
#define UART_ST_PARERR   (1u << 7)
#define UART_ST_IDLE     (1u << 8)

#define UART_CTRL_TXEN   (1u << 0)
#define UART_CTRL_RXEN   (1u << 1)
#define UART_CTRL_LOOP   (1u << 2)
#define UART_CTRL_RTSEN  (1u << 3)
#define UART_CTRL_TXCLR  (1u << 4)
#define UART_CTRL_RXCLR  (1u << 5)
#define UART_CTRL_CTSEN  (1u << 6)
#define UART_CTRL_PAR_NONE (0u << 8)
#define UART_CTRL_PAR_EVEN (2u << 8)
#define UART_CTRL_PAR_ODD  (3u << 8)
#define UART_CTRL_STOP2    (1u << 10)
#define UART_CTRL_BITS(n)  ((uint32_t)(n) << 11)

#define UART_IP_RXNE     (1u << 0)
#define UART_IP_RXWM     (1u << 1)
#define UART_IP_TXE      (1u << 2)
#define UART_IP_TXWM     (1u << 3)
#define UART_IP_IDLE     (1u << 4)
#define UART_IP_ERR      (1u << 5)

// ---- CLINT (standard offsets) ---------------------------------------
#define CLINT_MSIP      REG32(CLINT_BASE + 0x0000)
#define CLINT_MTIMECMPL REG32(CLINT_BASE + 0x4000)
#define CLINT_MTIMECMPH REG32(CLINT_BASE + 0x4004)
#define CLINT_MTIMEL    REG32(CLINT_BASE + 0xBFF8)
#define CLINT_MTIMEH    REG32(CLINT_BASE + 0xBFFC)

// ---- GPIO -----------------------------------------------------------
#define GPIO_OUT     REG32(GPIO_BASE + 0x00)
#define GPIO_IN      REG32(GPIO_BASE + 0x04)
#define GPIO_IE      REG32(GPIO_BASE + 0x08)
#define GPIO_IP      REG32(GPIO_BASE + 0x0C)
#define GPIO_OUT_SET REG32(GPIO_BASE + 0x10)
#define GPIO_OUT_CLR REG32(GPIO_BASE + 0x14)
#define GPIO_OUT_TGL REG32(GPIO_BASE + 0x18)

// ---- SYSCON: the SoC describes itself -------------------------------
#define SYS_TOHOST    REG32(SYSCON_BASE + 0x00)   // a write halts the core
#define SYS_CLK_HZ    REG32(SYSCON_BASE + 0x04)
#define SYS_MEM_WORDS REG32(SYSCON_BASE + 0x08)
#define SYS_SRAM_SIZE REG32(SYSCON_BASE + 0x0C)
#define SYS_IRQ_SRC   REG32(SYSCON_BASE + 0x10)   // b0 uart, b1 gpio

// ---- machine interrupt-enable bits ----------------------------------
#define MIE_MSIE (1u << 3)
#define MIE_MTIE (1u << 7)
#define MIE_MEIE (1u << 11)
#define MSTATUS_MIE (1u << 3)

// ---- CSR helpers ----------------------------------------------------
#define csr_read(csr) ({                              \
    uint32_t __v;                                     \
    __asm__ volatile ("csrr %0, " #csr : "=r"(__v));  \
    __v; })

#define csr_write(csr, val)                           \
    __asm__ volatile ("csrw " #csr ", %0" :: "rK"((uint32_t)(val)))

#define csr_set(csr, val)                             \
    __asm__ volatile ("csrs " #csr ", %0" :: "rK"((uint32_t)(val)))

#define csr_clear(csr, val)                           \
    __asm__ volatile ("csrc " #csr ", %0" :: "rK"((uint32_t)(val)))

static inline void wfi(void) { __asm__ volatile ("wfi"); }

// ---- runtime --------------------------------------------------------
void     uart_init(uint32_t baud);
void     uart_putc(char c);
int      uart_getc_nb(void);          // -1 if nothing waiting
char     uart_getc(void);             // blocks
void     uart_puts(const char *s);
void     uart_flush(void);

void     s6_printf(const char *fmt, ...);   // %c %s %d %u %x %p %%

uint64_t mtime_get(void);
void     delay_us(uint32_t us);

void     halt(uint32_t code) __attribute__((noreturn));

// Weak default in bsp.c; override it to handle your own traps.
uint32_t trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval);

#endif // S6_BSP_H
