/* fpga_demo.c - minimal program for the synthesizable BRAM SoC.
 * Prints a message over the real UART (polling the ready bit) and then
 * writes SYSCON to halt (lights the LED). No .rodata: characters are
 * immediates, so only zero-initialized stack RAM is needed. */
#include "firmware.h"     /* for UART_TX / UART_ST register macros */
#define SYSCON (*(volatile unsigned *)0x20000000)

static void pc(char c){
    while (!(UART_ST & 1u)) { }   /* wait until the UART is ready */
    UART_TX = (unsigned char)c;
}

int main(void){
    pc('R'); pc('V'); pc('3'); pc('2'); pc('I'); pc('M'); pc(' ');
    pc('o'); pc('n'); pc(' ');
    pc('Z'); pc('y'); pc('n'); pc('q'); pc(' ');
    pc('P'); pc('L'); pc('!'); pc('\n');
    SYSCON = 1;                   /* halt -> LED on */
    for(;;){ }
}
