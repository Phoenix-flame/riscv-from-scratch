/* uart_irq_demo.c - interrupt-driven "receive to idle".
 * An RX interrupt fires per byte (collected into a buffer); the IDLE
 * interrupt fires when the line goes quiet, delimiting a whole message.
 * main() then echoes the complete message back. */
#ifndef CLKS
#define CLKS 64
#endif
#define UART    0x10000000u
#define TXDATA  (*(volatile unsigned *)(UART + 0x00))
#define RXDATA  (*(volatile unsigned *)(UART + 0x04))
#define STATUS  (*(volatile unsigned *)(UART + 0x08))
#define CONFIG  (*(volatile unsigned *)(UART + 0x0C))
#define IEN     (*(volatile unsigned *)(UART + 0x10))
#define IPEND   (*(volatile unsigned *)(UART + 0x14))
#define IDLECFG (*(volatile unsigned *)(UART + 0x18))
#define IP_RXNE 1u
#define IP_IDLE 2u

volatile unsigned char rxbuf[64];
volatile unsigned rxlen, msg_ready, msg_len;

void __attribute__((interrupt("machine"), aligned(4))) trap_handler(void){
    unsigned p = IPEND;
    if (p & IP_RXNE){                       /* a byte arrived */
        unsigned c = RXDATA;                /* read clears rxne */
        if (rxlen < sizeof(rxbuf)) rxbuf[rxlen++] = (unsigned char)c;
    }
    if (p & IP_IDLE){                        /* line went idle -> message done */
        msg_len = rxlen; rxlen = 0; msg_ready = 1;
        IPEND = IP_IDLE;                     /* W1C clears the IDLE event */
    }
}

int main(void){
    rxlen = 0; msg_ready = 0;                /* init state */
    CONFIG  = (CLKS & 0xFFFFu) | (8u << 16); /* 8N1 */
    IDLECFG = 12;                            /* IDLE after ~12 idle bit-times */
    IEN     = IP_RXNE | IP_IDLE;             /* enable RX + IDLE interrupts */

    unsigned mtvec = (unsigned)&trap_handler;
    __asm__ volatile("csrw mtvec, %0" :: "r"(mtvec));
    __asm__ volatile("csrs mie,   %0" :: "r"(1u << 11));  /* MEIE */
    __asm__ volatile("csrs mstatus,%0":: "r"(1u << 3));   /* MIE  */

    for (;;){
        if (msg_ready){
            unsigned n = msg_len; msg_ready = 0;
            for (unsigned i = 0; i < n; i++){
                while (!(STATUS & 1u)) { }   /* wait tx_ready */
                TXDATA = rxbuf[i];           /* echo the whole message */
            }
        }
    }
    return 0;
}
