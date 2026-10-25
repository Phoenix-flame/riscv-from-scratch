/* =====================================================================
 * mhello.c  -  a payload entered in M-MODE (image flag RVBI_F_MMODE)
 * ---------------------------------------------------------------------
 * The escape hatch for bare-metal programs that want the whole machine
 * -- their own mtvec, no SBI underneath. Same boot convention (a0 = hart
 * ID, a1 = DTB), and still nothing hardcoded: the console comes from
 * /chosen/stdout-path, and the way out is the tree's syscon-reboot node,
 * followed the way Linux's driver does -- its `regmap` phandle names the
 * register block (the sifive,test device), `offset` and `value` say what
 * to write there. Writing it resets the machine into the boot ROM.
 * ===================================================================== */
#include <stdint.h>
#include "lib.h"
#include "fdt.h"
#include "ns16550.h"

#define csr_read(csr)  ({ uint32_t v_; __asm__ volatile("csrr %0, " #csr : "=r"(v_)); v_; })

static struct ns16550 con;
static void con_putc(int c) { ns16550_putc(&con, c); }

static uint32_t be32(const void *p) { return fdt32(*(const uint32_t *)p); }

static uint32_t prop_u32(const void *fdt, int node, const char *name)
{
    uint32_t v = 0;
    fdt_getprop_u32(fdt, node, name, &v);
    return v;
}

int main(uint32_t hartid, const void *fdt)
{
    if (fdt_check(fdt)) return 1;
    int u = fdt_resolve(fdt, fdt_getprop(fdt, fdt_path_offset(fdt, "/chosen"), "stdout-path", 0));
    if (u < 0) return 2;
    con.base     = be32(fdt_getprop(fdt, u, "reg", 0));
    con.shift    = (int)prop_u32(fdt, u, "reg-shift");
    con.io_width = (int)prop_u32(fdt, u, "reg-io-width");
    lib_putc = con_putc;                       /* the ROM left the UART configured */

    printf("mhello: M-mode payload, hart %u (mhartid %u), dtb %p\n", hartid, csr_read(mhartid), fdt);
    printf("  console %s at 0x%08x, straight from the tree; no SBI below us\n",
           fdt_get_name(fdt, u), (uint32_t)con.base);
    printf("  mtvec 0x%08x: still the ROM's SBI entry, ours to replace\n", csr_read(mtvec));

    int rb = fdt_path_offset(fdt, "/reboot");
    int len;
    const char *compat = fdt_getprop(fdt, rb, "compatible", &len);
    if (rb < 0 || !fdt_stringlist_contains(compat, len, "syscon-reboot")) return 3;
    int dev = fdt_node_by_phandle(fdt, prop_u32(fdt, rb, "regmap"));
    uint32_t base = be32(fdt_getprop(fdt, dev, "reg", 0));
    uint32_t off = prop_u32(fdt, rb, "offset"), val = prop_u32(fdt, rb, "value");
    printf("  /reboot: syscon-reboot, regmap -> %s, writes 0x%x at 0x%08x\n",
           fdt_get_name(fdt, dev), val, base + off);
    printf("mhello: rebooting\n");
    ns16550_flush(&con);
    *(volatile uint32_t *)(base + off) = val;
    for (;;) { }
}
