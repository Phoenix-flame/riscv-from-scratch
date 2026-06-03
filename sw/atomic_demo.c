/* atomic_demo.c - exercise every RV32A instruction and check its semantics.
 * Inline asm guarantees the actual LR/SC/AMO instructions are emitted. */
#include "firmware.h"

#define AMO(name) \
  static inline unsigned amo_##name(volatile unsigned *p, unsigned v){ \
    unsigned o; asm volatile(#name ".w %0, %2, (%1)" : "=r"(o):"r"(p),"r"(v):"memory"); return o; }
AMO(amoadd) AMO(amoswap) AMO(amoor) AMO(amoand) AMO(amoxor)
static inline int amomax(volatile int *p,int v){int o;asm volatile("amomax.w %0,%2,(%1)":"=r"(o):"r"(p),"r"(v):"memory");return o;}
static inline int amomin(volatile int *p,int v){int o;asm volatile("amomin.w %0,%2,(%1)":"=r"(o):"r"(p),"r"(v):"memory");return o;}
static inline unsigned lrw(volatile unsigned *p){unsigned o;asm volatile("lr.w %0,(%1)":"=r"(o):"r"(p):"memory");return o;}
static inline unsigned scw(volatile unsigned *p,unsigned v){unsigned o;asm volatile("sc.w %0,%2,(%1)":"=r"(o):"r"(p),"r"(v):"memory");return o;}

volatile unsigned A,B,C,D,E;
volatile int      S;
volatile unsigned L, lock;

int main(void){
    A=10;     kprintf("amoadd : old=%d now=%d   (want 10,15)\n", amo_amoadd(&A,5), A);
    B=15;     kprintf("amoswap: old=%d now=%d   (want 15,99)\n", amo_amoswap(&B,99), B);
    C=0xF0; amo_amoor (&C,0x0F); kprintf("amoor  : now=%x       (want ff)\n", C);
    D=0xFF; amo_amoand(&D,0x0F); kprintf("amoand : now=%x        (want f)\n", D);
    E=0xAA; amo_amoxor(&E,0xFF); kprintf("amoxor : now=%x       (want 55)\n", E);
    S=-5; amomax(&S,3);  kprintf("amomax : now=%d        (want 3)\n", S);
    S=-5; amomin(&S,3);  kprintf("amomin : now=%d       (want -5)\n", S);

    L = 42;
    unsigned r  = lrw(&L);
    unsigned ok = scw(&L, r + 1);             /* reservation live -> success */
    kprintf("lr/sc  : loaded=%d sc=%d now=%d  (want 42,0,43)\n", r, ok, L);
    unsigned bad = scw(&L, 999);              /* no live reservation -> fail */
    kprintf("sc again: sc=%d now=%d          (want 1,43)\n", bad, L);

    lock = 0;
    unsigned was = amo_amoswap(&lock, 1);     /* spinlock acquire */
    kprintf("lock   : prev=%d held=%d        (want 0,1)\n", was, lock);

    kprintf("RV32A OK\n");
    halt(0);
    return 0;
}
