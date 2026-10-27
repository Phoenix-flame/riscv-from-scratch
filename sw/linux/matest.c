/* =====================================================================
 * matest.c  -  misaligned accesses from user space (Step 53)
 * ---------------------------------------------------------------------
 * The core traps misaligned loads and stores (Step 52); Linux emulates
 * them, so a program sees the right bytes. A misaligned AMO cannot be
 * made atomic, so the kernel answers it with SIGBUS -- tried in a child.
 * The accesses are inline asm: the compiler would never emit them.
 * ===================================================================== */
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

static uint8_t buf[16] __attribute__((aligned(4)));

int main(void)
{
    for (int i = 0; i < 16; i++) buf[i] = 0x10 + i;
    uint32_t w, h, hu;
    __asm__ volatile("lw  %0, 1(%1)" : "=r"(w)  : "r"(buf) : "memory");
    __asm__ volatile("lh  %0, 3(%1)" : "=r"(h)  : "r"(buf) : "memory");
    __asm__ volatile("lhu %0, 7(%1)" : "=r"(hu) : "r"(buf) : "memory");
    __asm__ volatile("sw  %0, 9(%1)" :: "r"(0xa1b2c3d4u), "r"(buf) : "memory");
    int ok = w == 0x14131211u && h == 0x1413u && hu == 0x1817u &&
             buf[8] == 0x18 && buf[9] == 0xd4 && buf[10] == 0xc3 &&
             buf[11] == 0xb2 && buf[12] == 0xa1 && buf[13] == 0x1d;
    printf("lw @+1 = %08x, lh @+3 = %08x, lhu @+7 = %08x, sw @+9 -> %02x %02x %02x %02x: %s\n",
           (unsigned)w, (unsigned)h, (unsigned)hu, buf[9], buf[10], buf[11], buf[12],
           ok ? "ok" : "WRONG");
    fflush(stdout);

    pid_t p = fork();
    if (p == 0) {
        __asm__ volatile("amoadd.w zero, %1, (%0)" :: "r"(buf + 2), "r"(1) : "memory");
        _exit(0);
    }
    int st = 0;
    waitpid(p, &st, 0);
    printf("amoadd.w @+2 in a child: %s\n",
           WIFSIGNALED(st) ? (WTERMSIG(st) == SIGBUS ? "SIGBUS  ok" : "another signal")
                           : "no signal");
    return !ok;
}
