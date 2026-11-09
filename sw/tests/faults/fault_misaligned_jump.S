// cpu_tb: +expect_stop=MISALIGNED_FETCH +expect=sw/tests/faults/fault_misaligned_jump.expect
// A taken branch or jump to an address with bit 1 set stops the CPU (no
// compressed instructions). A NOT-taken branch with such a target is fine.
// JALR's bit-0 clearing is not a fault. The faulting JALR writes no link.
#include "riscv_test.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN
    li s0, 0x3000
    sw zero, 8(s0)
    .word 0x00001363        // bne x0, x0, +6: not taken, legal
    li a0, 1
    sw a0, 0(s0)
    la t0, 1f
    addi t0, t0, 1
    jalr zero, 0(t0)        // target 1f + 1 -> 1f: legal
    j 2f
1:  li a0, 2
    sw a0, 4(s0)
    la t1, 2f
    addi t1, t1, 2
    li ra, 0x5a5a
    jalr ra, 0(t1)          // target 2f + 2: stops here, ra unchanged
2:  sw ra, 8(s0)
    RVTEST_PASS
RVTEST_CODE_END
