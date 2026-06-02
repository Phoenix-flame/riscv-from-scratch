.section .text.init
.global _start
_start:
    li   sp, 0x1000
    li   a0, 5
    jal  ra, dbl        # call dbl(5); ra = return addr
    sw   a0, 0(zero)    # expect 10 in mem[0]
    li   t0, 0xBEEF
    sw   t0, 4(zero)    # marker: we returned from the call
1:  j    1b
dbl:
    slli a0, a0, 1      # a0 *= 2
    jr   ra             # jalr x0, 0(ra)  -- return
