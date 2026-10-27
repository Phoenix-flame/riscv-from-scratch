/* =====================================================================
 * qspi.c  -  linear reads and I/O-mode writes of the QSPI flash
 * ---------------------------------------------------------------------
 * The controller (UG585 ch. 12) at 0xe000_d000, on QSPI_REF_CLK = 200 MHz
 * (ps7_init), divided by 8: 25 MHz, well inside what a single-bit read or
 * fast read needs on any SPI NOR part, with no feedback clock (MIO 8 is a
 * GPIO on this board).
 *
 * I/O mode, as Xilinx's own flash writer drives it: chip select by hand,
 * transfers started by hand. A command is queued in the TX FIFO, started,
 * and done when as many words have come back as went out. TXD0 sends 4
 * bytes, least significant first; TXD1 sends 1. Page programs go 128 bytes
 * at a time, so a command (1 + 32 words) never overfills the 63-word FIFOs.
 * ===================================================================== */
#include "zynq.h"
#include "qspi.h"

#define QSPI          UINT32_C(0xe000d000)
#define Q_CR          (QSPI + 0x00)
#define Q_ISR         (QSPI + 0x04)
#define Q_IDR         (QSPI + 0x0c)
#define Q_ER          (QSPI + 0x14)
#define Q_TXD0        (QSPI + 0x1c)
#define Q_RXD         (QSPI + 0x20)
#define Q_TXD1        (QSPI + 0x80)
#define Q_LQSPI_CFG   (QSPI + 0xa0)

#define CR_IFMODE     (UINT32_C(1) << 31)       /* flash interface mode */
#define CR_HOLDB      (UINT32_C(1) << 19)       /* drive HOLD_B high */
#define CR_MANSTRT    (UINT32_C(1) << 16)       /* start the queued transfer */
#define CR_MANSTRTEN  (UINT32_C(1) << 15)
#define CR_MANCS      (UINT32_C(1) << 14)
#define CR_PCS        (UINT32_C(1) << 10)       /* 1: chip select high */
#define CR_FWIDTH     (UINT32_C(3) << 6)        /* 32-bit FIFO words (must be 3) */
#define CR_DIV8       (UINT32_C(2) << 3)        /* 200 MHz / 8 = 25 MHz */
#define CR_MSTREN     (UINT32_C(1) << 0)
#define CR_BASE       (CR_IFMODE | CR_HOLDB | CR_FWIDTH | CR_DIV8 | CR_MSTREN)
#define ISR_RXNEMPTY  (UINT32_C(1) << 4)
#define LQ_MODE       (UINT32_C(1) << 31)
#define LQ_FAST_READ  (UINT32_C(0x0b) | UINT32_C(1) << 8)   /* 0x0b, one dummy byte */

#define F_WREN   0x06
#define F_RDSR   0x05
#define F_RDID   0x9f
#define F_PP     0x02
#define F_BE64   0xd8
#define SR_WIP   1u
#define SR_WEL   2u
#define BLOCK    UINT32_C(0x10000)
#define CHUNK    128u

#ifdef PS_HOST_TEST
const uint8_t *host_flash_map(void);
#define LINEAR   host_flash_map()
#else
#define LINEAR   ((const uint8_t *)(uintptr_t)UINT32_C(0xfc000000))
#endif

static int timed_out;

static void mode(int linear)
{
    hw_wr(Q_ER, 0);
    if (linear) {
        hw_wr(Q_CR, CR_BASE);                  /* the controller drives chip select */
        hw_wr(Q_LQSPI_CFG, LQ_MODE | LQ_FAST_READ);
    } else {
        hw_wr(Q_LQSPI_CFG, 0);
        hw_wr(Q_CR, CR_BASE | CR_MANSTRTEN | CR_MANCS | CR_PCS);
        hw_wr(Q_IDR, 0x7f);                    /* polled: no interrupts */
    }
    hw_wr(Q_ER, 1);
    if (!linear)
        while (hw_rd(Q_ISR) & ISR_RXNEMPTY) (void)hw_rd(Q_RXD);
}

const uint8_t *qspi_map(void)
{
    mode(1);
    return LINEAR;
}

/* one command: w0 through TXD1 (one byte) or TXD0 (four), then nwords from
 * data; returns the last word received */
static uint32_t cmd(uint32_t w0, int one_byte, const uint8_t *data, uint32_t nwords)
{
    uint32_t cr = hw_rd(Q_CR) & ~CR_MANSTRT, v = 0;
    hw_wr(Q_CR, cr & ~CR_PCS);                 /* select */
    hw_wr(one_byte ? Q_TXD1 : Q_TXD0, w0);
    for (uint32_t i = 0; i < nwords; i++) {
        const uint8_t *p = data + 4 * i;
        hw_wr(Q_TXD0, (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24);
    }
    hw_wr(Q_CR, (cr & ~CR_PCS) | CR_MANSTRT);
    uint32_t got = 0;
    for (uint32_t spin = 0; got < nwords + 1; spin++) {
        if (hw_rd(Q_ISR) & ISR_RXNEMPTY) { v = hw_rd(Q_RXD); got++; }
        else if (spin > 10000000) { timed_out = 1; break; }
    }
    hw_wr(Q_CR, cr | CR_PCS);                  /* deselect */
    return v;
}

/* a command byte and a 24-bit address, most significant byte first */
static uint32_t cmd_addr(uint32_t c, uint32_t a)
{
    return c | (a >> 16 & 0xff) << 8 | (a >> 8 & 0xff) << 16 | (a & 0xff) << 24;
}

/* bytes 1..3 of the reply are the status register, sent over and over */
static uint32_t rdsr(void) { return cmd(F_RDSR, 0, 0, 0) >> 16 & 0xff; }

uint32_t qspi_jedec_id(void)
{
    mode(0);
    uint32_t v = cmd(F_RDID, 0, 0, 0);
    mode(1);
    return (v >> 8 & 0xff) << 16 | (v >> 16 & 0xff) << 8 | (v >> 24 & 0xff);
}

static int wren(void)
{
    cmd(F_WREN, 1, 0, 0);
    return (rdsr() & SR_WEL) ? 0 : -1;
}

static int wait_ready(void)
{
    for (uint32_t i = 0; i < 50000000u && !timed_out; i++)
        if (!(rdsr() & SR_WIP)) return 0;
    return -1;
}

int qspi_write(const uint8_t *src, uint32_t n, void (*progress)(uint32_t, uint32_t), const char **why)
{
    uint8_t buf[CHUNK];
    if (n == 0 || n > QSPI_FLASH_BYTES) { *why = "length out of range"; return -1; }
    timed_out = 0;
    mode(0);
    for (uint32_t blk = 0; blk < n; blk += BLOCK) {
        if (wren()) { *why = "the flash ignores write enable (status register WEL stays 0)"; goto fail; }
        cmd(cmd_addr(F_BE64, blk), 0, 0, 0);
        if (wait_ready()) { *why = "a block erase never finished"; goto fail; }
        for (uint32_t a = blk; a < blk + BLOCK && a < n; a += CHUNK) {
            uint32_t k = n - a < CHUNK ? n - a : CHUNK;
            for (uint32_t i = 0; i < CHUNK; i++) buf[i] = i < k ? src[a + i] : 0xff;
            if (wren()) { *why = "the flash ignores write enable (status register WEL stays 0)"; goto fail; }
            cmd(cmd_addr(F_PP, a), 0, buf, (k + 3) / 4);
            if (wait_ready()) { *why = "a page program never finished"; goto fail; }
        }
        if (progress) progress(blk + BLOCK < n ? blk + BLOCK : n, n);
    }
    /* a word at a time: each linear read is its own fast-read command */
    const uint32_t *f = (const uint32_t *)(const void *)qspi_map();
    const uint32_t *s = (const uint32_t *)(const void *)src;
    for (uint32_t i = 0; i < n / 4; i++)
        if (f[i] != s[i]) { *why = "reading it back does not match"; return -1; }
    for (uint32_t i = n & ~UINT32_C(3); i < n; i++)
        if (((const uint8_t *)f)[i] != src[i]) { *why = "reading it back does not match"; return -1; }
    return 0;
fail:
    if (timed_out) *why = "the controller never answered";
    mode(1);
    return -1;
}
