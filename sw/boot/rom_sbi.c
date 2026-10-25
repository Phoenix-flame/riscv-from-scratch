/* =====================================================================
 * rom_sbi.c  -  the resident SBI: what M-mode does for an S-mode payload
 * ---------------------------------------------------------------------
 * After the ROM mrets into a payload it is never called again -- except
 * through this file. mtvec points at sbi_trap_entry (rom_start.S), and
 * the only traps that still reach M are the ones the ROM did not
 * delegate:
 *
 *   ecall from S (cause 9)    an SBI call: a7 = EID, a6 = FID, a0..a5 args;
 *                             answer in a0 (error) / a1 (value), mepc += 4
 *   machine timer (int. 7)    S cannot see mtimecmp, so the SBI turns the
 *                             machine timer into the supervisor one: mask
 *                             MTIE and raise STIP, which IS delegated, so
 *                             the payload takes it at stvec. sbi_set_timer
 *                             re-arms: new mtimecmp, clear STIP, unmask MTIE.
 *   anything else             a fault the payload cannot handle: report
 *                             it and fail the run
 * ===================================================================== */
#include "rom.h"
#include "lib.h"
#include "sbi.h"

enum { RA = 1, SP = 2, A0 = 10, A1, A2, A3, A4, A5, A6, A7 };

static volatile uint32_t *const mtimecmp = (volatile uint32_t *)(CLINT_BASE + 0x4000);

static void set_timer(uint64_t t)
{
    mtimecmp[1] = 0xFFFFFFFFu;            /* never a moment where cmp is in the past */
    mtimecmp[0] = (uint32_t)t;
    mtimecmp[1] = (uint32_t)(t >> 32);
    csr_clear(mip, MIP_STIP);
    csr_set(mie, MIP_MTIP);
}

static int probe(uint32_t eid)
{
    switch (eid) {
    case SBI_EXT_BASE: case SBI_EXT_TIME: case SBI_EXT_DBCN: case SBI_EXT_SRST:
    case SBI_EXT_LEGACY_SET_TIMER: case SBI_EXT_LEGACY_PUTCHAR:
    case SBI_EXT_LEGACY_GETCHAR: case SBI_EXT_LEGACY_SHUTDOWN:
        return 1;
    default:
        return 0;
    }
}

/* a buffer the payload names by physical address must be its own memory */
static int payload_buffer(uint32_t lo, uint32_t hi, uint32_t n)
{
    return hi == 0 && lo >= PAYLOAD_BASE && lo + n >= lo && lo + n <= RAM_BASE + ram_size;
}

static void reset(uint32_t type, uint32_t reason)
{
    if (type == SBI_SRST_SHUTDOWN) fw_poweroff(reason == SBI_SRST_REASON_NONE ? 0 : 1);
    fw_reset();                           /* cold or warm: back to the ROM */
}

static void ecall(uint32_t *r)
{
    uint32_t eid = r[A7], fid = r[A6];
    long err = SBI_SUCCESS, val = 0;

    switch (eid) {
    /* ---- v0.1 legacy: a0 is the only result, everything else preserved */
    case SBI_EXT_LEGACY_SET_TIMER:
        set_timer(((uint64_t)r[A1] << 32) | r[A0]);
        r[A0] = 0;
        return;
    case SBI_EXT_LEGACY_PUTCHAR:
        ns16550_putc(&rom_uart, (int)r[A0]);
        r[A0] = 0;
        return;
    case SBI_EXT_LEGACY_GETCHAR:
        r[A0] = (uint32_t)ns16550_getc(&rom_uart);
        return;
    case SBI_EXT_LEGACY_SHUTDOWN:
        reset(SBI_SRST_SHUTDOWN, SBI_SRST_REASON_NONE);
        return;

    case SBI_EXT_BASE:
        switch (fid) {
        case SBI_BASE_GET_SPEC_VERSION: val = SBI_SPEC_VERSION; break;
        case SBI_BASE_GET_IMPL_ID:      val = SBI_IMPL_ID; break;
        case SBI_BASE_GET_IMPL_VERSION: val = SBI_IMPL_VERSION; break;
        case SBI_BASE_PROBE_EXTENSION:  val = probe(r[A0]); break;
        case SBI_BASE_GET_MVENDORID:    val = (long)csr_read(mvendorid); break;
        case SBI_BASE_GET_MARCHID:      val = (long)csr_read(marchid); break;
        case SBI_BASE_GET_MIMPID:       val = (long)csr_read(mimpid); break;
        default:                        err = SBI_ERR_NOT_SUPPORTED;
        }
        break;

    case SBI_EXT_TIME:
        if (fid == 0) set_timer(((uint64_t)r[A1] << 32) | r[A0]);
        else err = SBI_ERR_NOT_SUPPORTED;
        break;

    case SBI_EXT_DBCN:
        if (fid == SBI_DBCN_WRITE_BYTE) {
            ns16550_putc(&rom_uart, (int)(r[A0] & 0xff));
        } else if (fid == SBI_DBCN_WRITE || fid == SBI_DBCN_READ) {
            uint32_t n = r[A0];
            uint8_t *buf = (uint8_t *)r[A1];
            if (!payload_buffer(r[A1], r[A2], n)) { err = SBI_ERR_INVALID_PARAM; break; }
            if (fid == SBI_DBCN_WRITE) {
                for (uint32_t i = 0; i < n; i++) ns16550_putc(&rom_uart, buf[i]);
                val = (long)n;
            } else {                                  /* non-blocking: what is waiting */
                int c;
                while ((uint32_t)val < n && (c = ns16550_getc(&rom_uart)) >= 0) buf[val++] = (uint8_t)c;
            }
        } else err = SBI_ERR_NOT_SUPPORTED;
        break;

    case SBI_EXT_SRST:
        if (fid == 0 && r[A0] <= SBI_SRST_WARM_REBOOT && r[A1] <= SBI_SRST_REASON_FAILURE)
            reset(r[A0], r[A1]);
        err = (fid == 0) ? SBI_ERR_INVALID_PARAM : SBI_ERR_NOT_SUPPORTED;
        break;

    default:
        err = SBI_ERR_NOT_SUPPORTED;
    }
    r[A0] = (uint32_t)err;
    r[A1] = (uint32_t)val;
}

void sbi_trap(uint32_t *regs)
{
    uint32_t cause = csr_read(mcause);
    if (cause == 0x80000007u) {           /* machine timer -> supervisor timer */
        csr_clear(mie, MIP_MTIP);
        csr_set(mip, MIP_STIP);
        return;
    }
    if (cause == 9) {                     /* ecall from S */
        ecall(regs);
        csr_write(mepc, csr_read(mepc) + 4);
        return;
    }
    printf("\nsbi: unexpected trap from %c-mode: mcause 0x%x mepc 0x%08x mtval 0x%08x\n",
           "USHM"[(csr_read(mstatus) >> 11) & 3], cause, csr_read(mepc), csr_read(mtval));
    fw_poweroff(0x20);
}
