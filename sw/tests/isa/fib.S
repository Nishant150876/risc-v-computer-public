// cpu_tb: +expect=sw/tests/isa/fib.expect
// Fibonacci: fib(1) .. fib(20) stored as words at 0x2000.. (fib(1) = 1).
// The testbench checks the table against sw/tests/isa/fib.expect.
#include "riscv_test.h"
#include "check.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN
    li s0, 0x2000           // output table
    li s1, 20               // count
    li a0, 0                // fib(0)
    li a1, 1                // fib(1)
1:  sw a1, 0(s0)
    add a2, a0, a1
    mv a0, a1
    mv a1, a2
    addi s0, s0, 4
    addi s1, s1, -1
    bnez s1, 1b
    lw a3, -4(s0)
    CHECK(1, a3, 6765)      // fib(20)
    TEST_END
RVTEST_CODE_END
