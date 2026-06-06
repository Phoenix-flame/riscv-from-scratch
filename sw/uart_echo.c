/* uart_echo.c - configure the UART, then echo every received byte back.
 * Demonstrates the RX path + runtime config (baud/data/parity/stop). */
#ifndef CLKS
#define CLKS 1085            /* 125 MHz / 115200; override -DCLKS=16 for sim */
#endif
#define UART   0x10000000u
#define TXDATA (*(volatile unsigned *)(UART + 0x00))
#define RXDATA (*(volatile unsigned *)(UART + 0x04))
#define STATUS (*(volatile unsigned *)(UART + 0x08))
#define CONFIG (*(volatile unsigned *)(UART + 0x0C))
#define ST_TXRDY 0x1u
#define ST_RXVAL 0x2u
int main(void){
    /* [15:0]=clks  [19:16]=data_bits  [21:20]=parity(0/1/2)  [22]=stop2 -> 8N1 */
    CONFIG = (CLKS & 0xFFFFu) | (8u << 16) | (0u << 20) | (0u << 22);
    for (;;){
        while (!(STATUS & ST_RXVAL)) { }
        unsigned c = RXDATA;
        while (!(STATUS & ST_TXRDY)) { }
        TXDATA = c;
    }
    return 0;
}
