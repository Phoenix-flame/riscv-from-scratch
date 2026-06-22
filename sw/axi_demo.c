/* =====================================================================
 * axi_demo.c  -  Reach the PS over the AXI4-Lite master.
 * ---------------------------------------------------------------------
 * Addresses at 0x4000_0000 go out the AXI master to the PS (here a
 * wait-state AXI slave modelling DDR + a peripheral). Every access there
 * stalls the core until the AXI response returns -- the program is unaware,
 * it just reads and writes memory. Results land in local RAM for the
 * testbench to check, then SYSCON halts the core.
 * ===================================================================== */
#define PS(i)   (*(volatile unsigned *)(0x40000000u + (i)*4u))
#define R(i)    (*(volatile unsigned *)(0x100u + (i)*4u))
#define SENT    (*(volatile unsigned *)(0x200u))
#define SYSCON  (*(volatile unsigned *)(0x20000000u))

int main(void)
{
    unsigned sum = 0;

    /* burst of writes into PS DDR, then read them all back */
    for (unsigned i = 0; i < 16; i++) PS(i) = 0x1000u + i * 7u;
    for (unsigned i = 0; i < 16; i++) sum += PS(i);
    R(0) = sum;                          /* 16*0x1000 + 7*(0..15) = 0x10348 */

    /* read-modify-write a PS location (load-stall, then store-stall) */
    PS(20) = 100u;
    PS(20) = PS(20) + 23u;
    R(1) = PS(20);                       /* 123 */

    /* a value check that depends on a real AXI read returning the right word */
    R(2) = (PS(5) == (0x1000u + 5u * 7u)) ? 0xACEu : 0xBADu;

    SENT = 0x600Du;
    SYSCON = 1u;
    for (;;) { }
    return 0;
}
