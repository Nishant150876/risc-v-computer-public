// cpu_tb: +expect_stop=MISALIGNED_FETCH +expect=sw/tests/faults/fault_misaligned_branch.expect
// A taken BEQ to pc + 6 stops the CPU without retiring.
#include "riscv_test.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN
    li s0, 0x3000
    sw zero, 4(s0)
    li a0, 0x77
    sw a0, 0(s0)
    .word 0x00000363        // beq x0, x0, +6: taken, misaligned
    sw a0, 4(s0)
    RVTEST_PASS
RVTEST_CODE_END
