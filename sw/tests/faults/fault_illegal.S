// cpu_tb: +expect_stop=ILLEGAL +expect=sw/tests/faults/fault_illegal.expect
// An illegal instruction stops the CPU without retiring: nothing after it
// runs, and the store before it did happen.
#include "riscv_test.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN
    li s0, 0x3000
    sw zero, 4(s0)         // guard is initialized, never assumed to power up zero
    li a0, 0x600d
    sw a0, 0(s0)
    .word 0x0000000b        // custom-0 opcode: not RV32I
    li a0, 0xbad
    sw a0, 4(s0)
    RVTEST_PASS
RVTEST_CODE_END
