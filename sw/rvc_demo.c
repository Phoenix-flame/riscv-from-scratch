/* rvc_demo.c - exercise the C extension end to end.
 *
 * Built twice from this one source: -march=rv32im_zicsr for the baseline
 * core (soc_fpga / cpu_mc) and -march=rv32imc_zicsr for the compressed core
 * (soc_c / cpu_mc_c). Same program, same results, ~30% fewer code bytes.
 *
 * The workload is deliberately branchy and call-heavy so gcc emits a wide
 * spread of RVC forms (c.addi, c.li, c.lui, c.lw/sw, c.lwsp/swsp, c.mv,
 * c.add/sub/and/or/xor/andi, shifts, c.j, c.jal, c.jr, c.beqz/bnez ...),
 * and an ecall fires periodically so a trap+mret round-trips through
 * compressed code -- mepc must carry bit 1 for the return to land.
 *
 * Results at fixed RAM addresses: 0x800 checksum, 0x804 trap count,
 * 0x808 sentinel 0x600D; then a SYSCON write halts the core. */
#define M(a)    (*(volatile unsigned *)(a))
#define SYSCON  0x20000000u

volatile unsigned traps;

void __attribute__((interrupt("machine"), aligned(4))) trap_handler(void){
    unsigned epc;
    __asm__ volatile("csrr %0, mepc" : "=r"(epc));
    traps++;
    __asm__ volatile("csrw mepc, %0" :: "r"(epc + 4));  /* skip the ecall */
}

static unsigned __attribute__((noinline)) mix(unsigned x, unsigned y){
    return ((x << 3) ^ (y >> 2)) + (x & y) - (x | ~y);
}

static unsigned tab[8];

int main(void){
    unsigned acc = 0x1234;
    int i;
    traps = 0;
    __asm__ volatile("csrw mtvec, %0" :: "r"((unsigned)&trap_handler));

    for (i = 0; i < 8; i++) tab[i] = mix(i, acc + i);

    for (i = 0; i < 64; i++){
        unsigned v = tab[i & 7];
        switch (i & 3){
            case 0:  acc += v;            break;
            case 1:  acc ^= (v << 1);     break;
            case 2:  acc -= mix(v, i);    break;
            default: acc |= (v & 0xffu);  break;
        }
        if (acc & 1) acc = (acc >> 1) ^ 0xEDB88320u;   /* CRC-flavoured stir */
        else         acc >>= 1;
        if ((i & 15) == 7) __asm__ volatile("ecall");  /* trap round-trip x4 */
    }

    M(0x800) = acc;
    M(0x804) = traps;
    M(0x808) = 0x600D;
    M(SYSCON) = 1;            /* halt */
    for (;;) { }
    return 0;
}
