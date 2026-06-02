volatile unsigned *p = (volatile unsigned *)0;
int main(void){
    unsigned a = 100, b = 7;
    p[0] = a / b;        /* libgcc __udivsi3 -> expect 14 */
    p[1] = a % b;        /* expect 2 */
    p[2] = 0xABCD;       /* marker: reached the end */
    for(;;){}
}
