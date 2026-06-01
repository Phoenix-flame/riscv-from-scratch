/* soc_demo.c - drive peripherals; now WITH a string constant in .rodata */
#define UART_TX  (*(volatile unsigned char *)0x10000000)
#define TIMER    (*(volatile unsigned int  *)0x10010000)
#define SYSCON   (*(volatile unsigned int  *)0x20000000)
#define RAM0     (*(volatile unsigned int  *)0x00000000)

static void uart_putc(char c) { UART_TX = (unsigned char)c; }
static void uart_puts(const char* msg, int len) {
    for (int i = 0; i < len; i++) uart_putc(msg[i]);
}
int main(void) {
    uart_puts("Hello World\n", 12);
    unsigned t0 = TIMER;
    for (volatile int i = 0; i < 5; i++) { }
    unsigned t1 = TIMER;
    RAM0 = t1 - t0;
    SYSCON = 0;
    for (;;) { }
}
