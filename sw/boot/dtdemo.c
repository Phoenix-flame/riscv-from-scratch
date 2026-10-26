/* =====================================================================
 * dtdemo.c  -  a payload that knows nothing about the machine it runs on
 * ---------------------------------------------------------------------
 * Every other program in sw/ hardcodes the memory map. This one is told
 * it, the way Linux is: it is entered in S-mode with a0 = hart ID and
 * a1 = a device tree, and it has the SBI underneath it. It
 *
 *   1. talks to the SBI: spec version, implementation, which extensions
 *      exist, console output by both the v2.0 and the legacy call
 *   2. checks the DTB and prints the whole tree (dtc's DTS syntax)
 *   3. reads what a kernel needs from it -- the ISA, the MMU, the timebase,
 *      the RAM, the reserved firmware region, the command line, the
 *      console -- and DRIVES the console UART itself, with the base
 *      address, register stride and divisor found in the tree
 *   4. takes S-mode timer interrupts (timebase from the DT, deadlines set
 *      through SBI TIME) and an ebreak that is delegated straight to it
 *   5. exits as /chosen/bootargs says: rvfs.exit=reboot resets the
 *      machine back into the boot ROM, otherwise it powers off
 *
 * Built with lib.c / fdt.c / ns16550.c, NOT platform.h.
 * ===================================================================== */
#include <stdint.h>
#include "lib.h"
#include "fdt.h"
#include "sbi.h"
#include "ns16550.h"

#define csr_read(csr)      ({ uint32_t v_; __asm__ volatile("csrr %0, " #csr : "=r"(v_)); v_; })
#define csr_write(csr, v)  __asm__ volatile("csrw " #csr ", %0" :: "rK"(v))
#define csr_set(csr, v)    __asm__ volatile("csrs " #csr ", %0" :: "rK"(v))
#define csr_clear(csr, v)  __asm__ volatile("csrc " #csr ", %0" :: "rK"(v))

static int fails;

static void sbi_out(int c) { sbi_putchar(c); }

static void verdict(int cond)
{
    puts_raw(cond ? "  ok\n" : "  FAIL\n");
    if (!cond) fails++;
}

static void check(int cond, const char *what)
{
    printf("  %-56s", what);
    verdict(cond);
}

static uint64_t rdtime(void)
{
    uint32_t hi, lo;
    do { hi = csr_read(timeh); lo = csr_read(time); } while (hi != csr_read(timeh));
    return ((uint64_t)hi << 32) | lo;
}

static uint32_t be32(const void *p) { return fdt32(*(const uint32_t *)p); }

/* ---- printing a tree the way `dtc -O dts` does ------------------------ */
static int is_stringlist(const uint8_t *v, int len)
{
    if (len == 0 || v[len - 1] != 0 || v[0] == 0) return 0;
    for (int i = 0; i < len; i++) {
        if (v[i] == 0) { if (i + 1 < len && v[i + 1] == 0) return 0; }
        else if (v[i] < 0x20 || v[i] > 0x7e) return 0;
    }
    return 1;
}

static void print_value(const uint8_t *v, int len)
{
    if (len == 0) return;
    puts_raw(" = ");
    if (is_stringlist(v, len)) {
        for (int i = 0; i < len; i += (int)strlen((const char *)v + i) + 1)
            printf("%s\"%s\"", i ? ", " : "", (const char *)v + i);
    } else if (len % 4 == 0) {
        puts_raw("<");
        for (int i = 0; i < len; i += 4) printf("%s0x%x", i ? " " : "", be32(v + i));
        puts_raw(">");
    } else {
        puts_raw("[");
        for (int i = 0; i < len; i++) printf("%s%02x", i ? " " : "", v[i]);
        puts_raw("]");
    }
}

static void indent(int d) { while (d--) puts_raw("    "); }

static void dump(const void *fdt, int node, int depth)
{
    const char *name = fdt_get_name(fdt, node);
    indent(depth);
    printf("%s {\n", *name ? name : "/");
    for (int p = fdt_first_prop(fdt, node); p >= 0; p = fdt_next_prop(fdt, p)) {
        const char *pn;
        int len;
        const uint8_t *v = fdt_prop_value(fdt, p, &pn, &len);
        indent(depth + 1);
        puts_raw(pn);
        print_value(v, len);
        puts_raw(";\n");
    }
    for (int s = fdt_first_subnode(fdt, node); s >= 0; s = fdt_next_subnode(fdt, s))
        dump(fdt, s, depth + 1);
    indent(depth);
    puts_raw("};\n");
}

/* a reg property's first (address, size) pair, for the node's parent cells */
static int reg_of(const void *fdt, int parent, int node, uint32_t *addr, uint32_t *size)
{
    uint32_t ac = 2, sc = 1;                          /* the spec's defaults */
    fdt_getprop_u32(fdt, parent, "#address-cells", &ac);
    fdt_getprop_u32(fdt, parent, "#size-cells", &sc);
    int len;
    const uint8_t *r = fdt_getprop(fdt, node, "reg", &len);
    if (!r || ac != 1 || sc > 1 || len < (int)(4 * (ac + sc))) return -1;   /* RV32: one cell */
    *addr = be32(r);
    *size = sc ? be32(r + 4) : 0;
    return 0;
}

/* ---- traps taken in S-mode ------------------------------------------- */
static volatile uint32_t ticks, breaks;
static volatile uint64_t tick_time[8];

static void __attribute__((interrupt("supervisor"), aligned(4))) s_trap(void)
{
    uint32_t cause = csr_read(scause);
    if (cause == 0x80000005u) {                      /* supervisor timer */
        if (ticks < 8) tick_time[ticks] = rdtime();
        ticks++;
        sbi_set_timer(~0ull);                        /* clears STIP until the next one */
    } else if (cause == 3) {                         /* ebreak, delegated by the ROM */
        breaks++;
        csr_write(sepc, csr_read(sepc) + 4);
    } else {
        printf("dtdemo: unexpected trap, scause 0x%x sepc 0x%08x\n", cause, csr_read(sepc));
        sbi_system_reset(SBI_SRST_SHUTDOWN, SBI_SRST_REASON_FAILURE);
    }
}

/* Rewrite the instruction right behind the store -- `li a0, 0` becomes
 * `li a0, 1` -- and return what a0 ends up holding. The core has
 * already fetched it by the time the store writes memory, so without a
 * FENCE.I the stale copy runs; FENCE.I refetches what follows it. */
#define LI_A0_1 0x00100513u
static uint32_t patch_next(void)
{
    register uint32_t a0 __asm__("a0");
    __asm__ volatile("la   t0, 1f\n\t"
                     "sw   %1, 0(t0)\n\t"
                     "nop\n"
                     "1:   li   a0, 0\n\t"
                     : "=r"(a0) : "r"(LI_A0_1) : "t0", "memory");
    return a0;
}
static uint32_t patch_next_fenced(void)
{
    register uint32_t a0 __asm__("a0");
    __asm__ volatile("la   t0, 1f\n\t"
                     "sw   %1, 0(t0)\n\t"
                     "fence.i\n"
                     "1:   li   a0, 0\n\t"
                     : "=r"(a0) : "r"(LI_A0_1) : "t0", "memory");
    return a0;
}

static uint32_t bootarg_u32(const char *args, const char *key, uint32_t dflt)
{
    const char *p = args ? strstr(args, key) : 0;
    if (!p) return dflt;
    uint32_t v = 0;
    for (p += strlen(key); *p >= '0' && *p <= '9'; p++) v = v * 10 + (uint32_t)(*p - '0');
    return v;
}

int main(uint32_t hartid, const void *fdt)
{
    lib_putc = sbi_out;
    printf("dtdemo: running in S-mode on hart %u, device tree at %p\n", hartid, fdt);

    /* ---- 1. the SBI ---- */
    printf("\n[SBI]\n");
    uint32_t ver = (uint32_t)sbi_call(SBI_EXT_BASE, SBI_BASE_GET_SPEC_VERSION, 0, 0, 0).value;
    uint32_t impl = (uint32_t)sbi_call(SBI_EXT_BASE, SBI_BASE_GET_IMPL_ID, 0, 0, 0).value;
    long iver = sbi_call(SBI_EXT_BASE, SBI_BASE_GET_IMPL_VERSION, 0, 0, 0).value;
    printf("  spec v%u.%u, implementation 0x%08x (\"%c%c%c%c\") version %d\n",
           ver >> 24, ver & 0xffffff, impl, impl >> 24, (impl >> 16) & 0xff, (impl >> 8) & 0xff,
           impl & 0xff, (int)iver);
    static const struct { uint32_t eid; const char *name; int want; } ext[] = {
        { SBI_EXT_BASE, "BASE", 1 }, { SBI_EXT_TIME, "TIME", 1 }, { SBI_EXT_DBCN, "DBCN", 1 },
        { SBI_EXT_SRST, "SRST", 1 }, { SBI_EXT_LEGACY_PUTCHAR, "legacy putchar", 1 },
        { SBI_EXT_HSM, "HSM (not implemented)", 0 },
    };
    for (unsigned i = 0; i < sizeof ext / sizeof ext[0]; i++) {
        long got = sbi_probe(ext[i].eid);
        printf("  probe_extension %-24s -> %d          ", ext[i].name, (int)got);
        verdict(got == ext[i].want);
    }
    static const char msg[] = "  (this line went out through one DBCN write call)\n";
    struct sbiret w = sbi_call(SBI_EXT_DBCN, SBI_DBCN_WRITE, sizeof msg - 1, (uint32_t)msg, 0);
    check(w.error == 0 && w.value == (long)sizeof msg - 1, "DBCN write returns the byte count");
    puts_raw("  legacy console_putchar: ");
    for (const char *s = "abc"; *s; s++) sbi_call(SBI_EXT_LEGACY_PUTCHAR, 0, (uint32_t)*s, 0, 0);
    puts_raw("\n");
    check(sbi_call(0x0A000000u, 0, 0, 0, 0).error == SBI_ERR_NOT_SUPPORTED,
          "unknown extension -> SBI_ERR_NOT_SUPPORTED");
    check(sbi_call(SBI_EXT_DBCN, SBI_DBCN_WRITE, 4, 0x80000000u, 0).error == SBI_ERR_INVALID_PARAM,
          "DBCN write from firmware memory refused");

    /* ---- 2. the tree itself ---- */
    printf("\n[device tree]\n");
    int err = fdt_check(fdt);
    check(err == 0, "DTB header: magic 0xd00dfeed, version 17");
    if (err) return 1;
    printf("  %u bytes, structure %u, strings %u\n\n", fdt_totalsize(fdt), fdt_hdr(fdt, 9), fdt_hdr(fdt, 8));
    dump(fdt, 0, 0);

    /* ---- 3. what a kernel reads from it ---- */
    printf("\n[what the tree says]\n");
    printf("  model         %s\n", (const char *)fdt_getprop(fdt, 0, "model", 0));
    int cpus = fdt_path_offset(fdt, "/cpus");
    int cpu0 = fdt_path_offset(fdt, "/cpus/cpu@0");
    uint32_t timebase = 0;
    fdt_getprop_u32(fdt, cpus, "timebase-frequency", &timebase);
    printf("  cpu@0         %s, %s\n", (const char *)fdt_getprop(fdt, cpu0, "riscv,isa", 0),
           (const char *)fdt_getprop(fdt, cpu0, "mmu-type", 0));
    printf("  timebase      %u Hz\n", timebase);
    uint32_t ram_base = 0, ram_size = 0, fw_base = 0, fw_size = 0;
    reg_of(fdt, 0, fdt_path_offset(fdt, "/memory"), &ram_base, &ram_size);
    int rsv = fdt_path_offset(fdt, "/reserved-memory");
    reg_of(fdt, rsv, fdt_first_subnode(fdt, rsv), &fw_base, &fw_size);
    printf("  memory        0x%08x, %u KiB\n", ram_base, ram_size >> 10);
    printf("  reserved      0x%08x, %u KiB (%s)\n", fw_base, fw_size >> 10,
           fdt_get_name(fdt, fdt_first_subnode(fdt, rsv)));
    int chosen = fdt_path_offset(fdt, "/chosen");
    const char *args = fdt_getprop(fdt, chosen, "bootargs", 0);
    const char *out = fdt_getprop(fdt, chosen, "stdout-path", 0);
    printf("  bootargs      \"%s\"\n", args ? args : "");
    check(ram_size >= 64 * 1024 && ram_base + ram_size > (uint32_t)fdt,
          "the DTB lies inside the RAM the DTB describes");
    check(fw_base + fw_size <= (uint32_t)&main, "this program lies above the firmware");

    int con = fdt_resolve(fdt, out);
    int len;
    const char *compat = fdt_getprop(fdt, con, "compatible", &len);
    uint32_t base = 0, size = 0, shift = 0, width = 1, clk = 0, baud = 0;
    reg_of(fdt, fdt_path_offset(fdt, "/soc"), con, &base, &size);
    fdt_getprop_u32(fdt, con, "reg-shift", &shift);
    fdt_getprop_u32(fdt, con, "reg-io-width", &width);
    fdt_getprop_u32(fdt, con, "clock-frequency", &clk);
    fdt_getprop_u32(fdt, con, "current-speed", &baud);
    printf("  stdout-path   \"%s\" -> %s, \"%s\"\n", out, fdt_get_name(fdt, con), compat);
    printf("                reg 0x%08x, stride %u, %u-byte access, %u Hz / 16 / %u baud\n",
           base, 1u << shift, width, clk, baud);
    check(con >= 0 && fdt_stringlist_contains(compat, len, "ns16550a"),
          "console is a 16550: a driver we have");

    /* ---- ... and drive that UART directly, configured from the tree ---- */
    struct ns16550 uart = { base, (int)shift, (int)width };
    unsigned divisor = baud ? clk / (16 * baud) : 1;
    ns16550_flush(&uart);                             /* the SBI's bytes are on the wire */
    ns16550_init(&uart, divisor);
    for (const char *s = "  hello from dtdemo's own 16550 driver, divisor "; *s; s++)
        ns16550_putc(&uart, *s);
    ns16550_putc(&uart, '0' + (int)divisor % 10);
    ns16550_putc(&uart, '\r');
    ns16550_putc(&uart, '\n');

    /* ---- 4. S-mode traps: timer interrupts and a delegated ebreak ---- */
    printf("\n[S-mode traps]\n");
    uint32_t nticks = bootarg_u32(args, "rvfs.ticks=", 2);
    if (nticks > 8) nticks = 8;
    uint64_t period = timebase / 10000;               /* 100 us */
    csr_write(stvec, (uint32_t)&s_trap);
    csr_set(sie, 1u << 5);                            /* STIE */
    csr_set(sstatus, 1u << 1);                        /* SIE */
    uint64_t deadline[8];
    for (uint32_t i = 0; i < nticks; i++) {
        deadline[i] = rdtime() + period;
        sbi_set_timer(deadline[i]);
        uint64_t give_up = deadline[i] + 10 * period;
        while (ticks == i && rdtime() < give_up) __asm__ volatile("wfi");
    }
    csr_clear(sstatus, 1u << 1);
    int on_time = ticks == nticks;
    for (uint32_t i = 0; i < nticks && i < ticks; i++) on_time &= tick_time[i] >= deadline[i];
    printf("  %u timer interrupts, %u ticks apart, none early (rvfs.ticks=%u)    ",
           ticks, (uint32_t)period, nticks);
    verdict(on_time);
    __asm__ volatile("ebreak");
    check(breaks == 1, "ebreak taken at stvec (scause 3), M-mode not involved");

    /* ---- self-modifying code, as a loader's last step is ---- */
    printf("\n[storing an instruction]\n");
    printf("  store over the next instruction, then nop:     a0 = %u (the stale copy ran)\n",
           patch_next());
    check(patch_next_fenced() == 1, "store over the next instruction, then fence.i: a0 = 1");

    /* ---- 5. leave as asked ---- */
    printf("\ndtdemo: %s\n", fails ? "FAILED" : "all checks passed");
    if (args && strstr(args, "rvfs.exit=reboot")) {
        printf("dtdemo: rvfs.exit=reboot -> SBI system reset\n");
        sbi_system_reset(SBI_SRST_COLD_REBOOT, SBI_SRST_REASON_NONE);
    }
    return fails != 0;
}
