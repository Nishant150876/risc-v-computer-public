/* RV32I/ILP32 startup. RAM initialization supplies .data; reset does not
   clear RAM or registers. Initialize ABI state and clear the ELF's .bss. */
    .section .text.init, "ax", @progbits
    .align 2
    .globl _start
    .type _start, @function
_start:
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, __stack_top
    li tp, 0
    la t0, __bss_start
    la t1, __bss_end
1:  bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:  call main
    /* main may return. Keep its status in a0 and stop without a trap/CSR. */
    ebreak
3:  j 3b
    .size _start, . - _start
