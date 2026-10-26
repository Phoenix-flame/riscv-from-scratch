/* =====================================================================
 * sbi.h  -  the RISC-V Supervisor Binary Interface, as this ROM serves it
 * ---------------------------------------------------------------------
 * An S-mode program (a kernel) asks the M-mode firmware underneath it
 * for the things only M can do with an `ecall`: a7 = extension ID (EID),
 * a6 = function ID (FID), a0..a5 = arguments; the firmware answers
 * a0 = error, a1 = value. Linux needs exactly this to boot: the timer
 * (it cannot write mtimecmp), a console before its own driver runs, and
 * a way to power off or reboot.
 *
 * The ROM implements SBI v2.0's BASE, TIME, DBCN (debug console) and
 * SRST (system reset) extensions, plus the legacy v0.1 set_timer /
 * console_putchar / console_getchar / shutdown calls. The inline
 * wrappers at the bottom are for payloads running in S-mode.
 * ===================================================================== */
#ifndef SBI_H
#define SBI_H

#include <stdint.h>

#define SBI_EXT_LEGACY_SET_TIMER  0x00
#define SBI_EXT_LEGACY_PUTCHAR    0x01
#define SBI_EXT_LEGACY_GETCHAR    0x02
#define SBI_EXT_LEGACY_SHUTDOWN   0x08
#define SBI_EXT_BASE              0x10
#define SBI_EXT_TIME              0x54494D45u   /* "TIME" */
#define SBI_EXT_DBCN              0x4442434Eu   /* "DBCN" */
#define SBI_EXT_SRST              0x53525354u   /* "SRST" */
#define SBI_EXT_HSM               0x0048534Du   /* "HSM" -- not implemented */

#define SBI_BASE_GET_SPEC_VERSION 0
#define SBI_BASE_GET_IMPL_ID      1
#define SBI_BASE_GET_IMPL_VERSION 2
#define SBI_BASE_PROBE_EXTENSION  3
#define SBI_BASE_GET_MVENDORID    4
#define SBI_BASE_GET_MARCHID      5
#define SBI_BASE_GET_MIMPID       6

#define SBI_DBCN_WRITE            0
#define SBI_DBCN_READ             1
#define SBI_DBCN_WRITE_BYTE       2

#define SBI_SRST_SHUTDOWN         0
#define SBI_SRST_COLD_REBOOT      1
#define SBI_SRST_WARM_REBOOT      2
#define SBI_SRST_REASON_NONE      0
#define SBI_SRST_REASON_FAILURE   1

#define SBI_SUCCESS               0
#define SBI_ERR_FAILED           -1
#define SBI_ERR_NOT_SUPPORTED    -2
#define SBI_ERR_INVALID_PARAM    -3
#define SBI_ERR_INVALID_ADDRESS  -5

#define SBI_SPEC_VERSION          0x02000000u   /* 2.0: major << 24 | minor */
#define SBI_IMPL_ID               0x52564653u   /* "RVFS" -- unregistered, ours */
#define SBI_IMPL_VERSION          49            /* the tutorial step */

struct sbiret { long error; long value; };

static inline struct sbiret sbi_call(uint32_t eid, uint32_t fid, uint32_t a0, uint32_t a1,
                                     uint32_t a2)
{
    register uint32_t r_a0 __asm__("a0") = a0;
    register uint32_t r_a1 __asm__("a1") = a1;
    register uint32_t r_a2 __asm__("a2") = a2;
    register uint32_t r_a6 __asm__("a6") = fid;
    register uint32_t r_a7 __asm__("a7") = eid;
    __asm__ volatile("ecall" : "+r"(r_a0), "+r"(r_a1)
                     : "r"(r_a2), "r"(r_a6), "r"(r_a7) : "memory");
    struct sbiret r = { (long)r_a0, (long)r_a1 };
    return r;
}

static inline long sbi_probe(uint32_t eid)
{
    return sbi_call(SBI_EXT_BASE, SBI_BASE_PROBE_EXTENSION, eid, 0, 0).value;
}
static inline void sbi_putchar(int c)
{
    sbi_call(SBI_EXT_DBCN, SBI_DBCN_WRITE_BYTE, (uint32_t)c, 0, 0);
}
static inline long sbi_set_timer(uint64_t t)
{
    return sbi_call(SBI_EXT_TIME, 0, (uint32_t)t, (uint32_t)(t >> 32), 0).error;
}
static inline void sbi_system_reset(uint32_t type, uint32_t reason)
{
    sbi_call(SBI_EXT_SRST, 0, type, reason, 0);
}

#endif
