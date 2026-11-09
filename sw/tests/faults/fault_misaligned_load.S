// cpu_tb: +expect_stop=MISALIGNED_LOAD +expect=sw/tests/faults/fault_misaligned_load.expect
// LH at an odd address stops the CPU; the destination register is not written
// (the following store, which would record it, never runs).
#include "riscv_test.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN
    li s0, 0x3000
    sw zero, 12(s0)
    li a0, 0x8899aabb
    sw a0, 0(s0)
    lbu a1, 3(s0)           // legal
    lhu a2, 2(s0)           // legal
    sw a1, 4(s0)
    sw a2, 8(s0)
    lh a3, 1(s0)            // misaligned: stops here
    sw a3, 12(s0)
    RVTEST_PASS
RVTEST_CODE_END
