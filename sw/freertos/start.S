# start.S - startup for FreeRTOS on this core.
#   sets the stack, zeroes .bss, installs the FreeRTOS trap vector, calls main.
        .section .text.init
        .globl _start
        .extern freertos_risc_v_trap_handler
        .extern main
_start:
        la   sp, __stack_top
        # zero .bss
        la   t0, __bss_start
        la   t1, __bss_end
1:      bgeu t0, t1, 2f
        sw   zero, 0(t0)
        addi t0, t0, 4
        j    1b
2:      # install the FreeRTOS trap handler as the (direct) machine trap vector
        la   t0, freertos_risc_v_trap_handler
        csrw mtvec, t0
        call main
3:      j    3b
