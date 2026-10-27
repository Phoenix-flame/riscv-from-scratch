/* =====================================================================
 * pcap.c  -  program the PL from the PS, through the DevC's PCAP
 * ---------------------------------------------------------------------
 * What an FSBL does with a BOOT.BIN's bitstream (UG585 6.4.2), in the
 * order U-Boot's zynqpl driver does it:
 *
 *   1. hold the fabric's resets and close the PS->PL level shifters;
 *   2. PCAP, not ICAP; PROG_B pulsed, so the PL clears, and INIT waited for;
 *   3. one DMA from memory to the PCAP (destination 0xffffffff), the
 *      source's bit 0 marking it as the last;
 *   4. wait for DMA done, then for the PL's DONE.
 *
 * The level shifters and resets are opened again by ps7_post_config().
 * The source must be in DDR or OCM, word-aligned, with the bitstream's
 * words as bootgen and mkbootimage store them (the sync word reads as
 * 0xaa995566).
 * ===================================================================== */
#include "zynq.h"
#include "pcap.h"

#define DEVC              UINT32_C(0xf8007000)
#define D_CTRL            (DEVC + 0x000)
#define D_INT_STS         (DEVC + 0x00c)
#define D_STATUS          (DEVC + 0x014)
#define D_DMA_SRC         (DEVC + 0x018)
#define D_DMA_DST         (DEVC + 0x01c)
#define D_DMA_SRC_LEN     (DEVC + 0x020)
#define D_DMA_DST_LEN     (DEVC + 0x024)
#define D_UNLOCK          (DEVC + 0x034)
#define D_MCTRL           (DEVC + 0x080)

#define CTRL_PROG_B       (UINT32_C(1) << 30)
#define CTRL_PCAP_PR      (UINT32_C(1) << 27)
#define CTRL_PCAP_MODE    (UINT32_C(1) << 26)
#define CTRL_PCAP_RATE_EN (UINT32_C(1) << 25)   /* encrypted bitstreams only */
#define STS_PCFG_INIT     (UINT32_C(1) << 4)
#define STS_DMA_Q_FULL    (UINT32_C(1) << 31)
#define INT_DMA_DONE      (UINT32_C(1) << 13)
#define INT_PCFG_DONE     (UINT32_C(1) << 2)
#define INT_FATAL         UINT32_C(0x00740040)  /* AXI errors, RX FIFO overflow, HMAC */
#define MCTRL_PCAP_LPBK   (UINT32_C(1) << 4)

#define SPIN              100000000u

static int wait_for(uint32_t reg, uint32_t mask, uint32_t want)
{
    for (uint32_t i = 0; i < SPIN; i++) {
        if ((hw_rd(reg) & mask) == want) return 0;
        if (reg == D_INT_STS && (hw_rd(D_INT_STS) & INT_FATAL)) return -2;
    }
    return -1;
}

int pcap_load(const uint32_t *bit, uint32_t words, const char **why)
{
    hw_wr(SLCR_UNLOCK, 0xdf0d);
    hw_wr(SLCR_FPGA_RST, 0xf);                 /* the fabric's AXI ports held in reset */
    hw_wr(SLCR_LVL_SHFTR, 0xa);                /* PL->PS only while it is configured */
    hw_wr(SLCR_LOCK, 0x767b);

    hw_wr(D_UNLOCK, UINT32_C(0x757bdf0d));
    hw_wr(D_MCTRL, hw_rd(D_MCTRL) & ~MCTRL_PCAP_LPBK);
    hw_wr(D_CTRL, (hw_rd(D_CTRL) | CTRL_PCAP_PR | CTRL_PCAP_MODE) & ~CTRL_PCAP_RATE_EN);
    hw_wr(D_INT_STS, 0xffffffff);

    hw_wr(D_CTRL, hw_rd(D_CTRL) | CTRL_PROG_B);
    hw_wr(D_CTRL, hw_rd(D_CTRL) & ~CTRL_PROG_B);
    if (wait_for(D_STATUS, STS_PCFG_INIT, 0)) { *why = "the PL never went into INIT"; return -1; }
    hw_wr(D_CTRL, hw_rd(D_CTRL) | CTRL_PROG_B);
    hw_wr(D_INT_STS, INT_PCFG_DONE);
    if (wait_for(D_STATUS, STS_PCFG_INIT, STS_PCFG_INIT)) { *why = "the PL never left INIT"; return -1; }
    if (hw_rd(D_STATUS) & STS_DMA_Q_FULL) { *why = "the DevC DMA queue is full"; return -1; }

    hw_wr(D_DMA_SRC, (uint32_t)(uintptr_t)bit | 1);
    hw_wr(D_DMA_DST, 0xffffffff);
    hw_wr(D_DMA_SRC_LEN, words);
    hw_wr(D_DMA_DST_LEN, 0);
    int r = wait_for(D_INT_STS, INT_DMA_DONE, INT_DMA_DONE);
    if (r) { *why = r == -2 ? "the DMA reported an error" : "the DMA never finished"; return -1; }
    hw_wr(D_INT_STS, INT_DMA_DONE);
    r = wait_for(D_INT_STS, INT_PCFG_DONE, INT_PCFG_DONE);
    if (r) { *why = "the PL never raised DONE: not a bitstream for this part?"; return -1; }
    return 0;
}

/* the sync word in the first 64 words: 0 if PCAP can take it as it is,
 * 1 if it needs each word byte-swapped, -1 if there is none */
int pcap_order(const uint32_t *bit, uint32_t words)
{
    for (uint32_t i = 0; i < words && i < 64; i++) {
        if (bit[i] == UINT32_C(0xaa995566)) return 0;
        if (bit[i] == UINT32_C(0x665599aa)) return 1;
    }
    return -1;
}
