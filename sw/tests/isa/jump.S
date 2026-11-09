// Jumps: JAL and JALR link values, JALR clears target bit 0, rd = rs1 for
// JALR (the target uses the old rs1), JAL to x0, and nested calls.
#include "riscv_test.h"
#include "check.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN
    // JAL writes pc + 4 and skips the instruction after it.
    li a2, 0
j1: jal ra, 1f
    li a2, 1
1:  la t0, j1 + 4
    li TESTNUM, 1
    bne ra, t0, fail
    CHECK(2, a2, 0)

    // JAL with rd = x0 jumps without writing.
    jal zero, 2f
    j fail
2:  CHECK(3, zero, 0)

    // JALR: target = (rs1 + imm) with bit 0 cleared.
    la t1, 3f
    addi t1, t1, -3
j2: jalr ra, 4(t1)          // (3f - 3 + 4) = 3f + 1 -> 3f
    j fail
3:  la t0, j2 + 4
    li TESTNUM, 4
    bne ra, t0, fail

    // JALR with rd = rs1: the target is computed from the old value.
    la t2, 4f
j3: jalr t2, 0(t2)
    j fail
4:  la t0, j3 + 4
    li TESTNUM, 5
    bne t2, t0, fail

    // Nested calls with the return address saved on a stack.
    li sp, 0x10000
    li a0, 0
    call outer
    CHECK(6, a0, 111)
    TEST_END

outer:
    addi sp, sp, -16
    sw ra, 12(sp)
    addi a0, a0, 100
    call inner
    lw ra, 12(sp)
    addi sp, sp, 16
    ret
inner:
    addi a0, a0, 11
    ret
RVTEST_CODE_END
