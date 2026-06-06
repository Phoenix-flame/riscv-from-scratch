/* dbg_demo.c - a program to debug: a loop updating a global counter and a
 * running sum, so a debugger can halt it, inspect state, breakpoint, and step. */
#include "firmware.h"
volatile unsigned counter;     /* updated every iteration */
volatile unsigned total;
int main(void){
    unsigned t = 0;
    for (unsigned i = 1; i <= 200000u; i++){
        counter = i;
        t += i;
        total = t;
    }
    *(volatile unsigned *)0x300 = total;
    halt(0);
}
