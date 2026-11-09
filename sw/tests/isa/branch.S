// Branches: each of BEQ BNE BLT BGE BLTU BGEU taken and not taken, signed vs
// unsigned disagreement (-1 vs 1), equal operands, and backward loops.
#include "riscv_test.h"
#include "check.h"

// Expect the branch to be taken: falls through to fail otherwise.
#define TAKEN(n, inst, a, b) \
    li TESTNUM, n; inst a, b, 1f; j fail; 1:
// Expect the branch not to be taken.
#define NOT_TAKEN(n, inst, a, b) \
    li TESTNUM, n; inst a, b, fail

RVTEST_RV32U
RVTEST_CODE_BEGIN
    li s0, -1
    li s1, 1
    li s2, 0x80000000
    li s3, 0x7fffffff

    TAKEN(1, beq, s1, s1)
    NOT_TAKEN(2, beq, s0, s1)
    TAKEN(3, bne, s0, s1)
    NOT_TAKEN(4, bne, zero, zero)
    TAKEN(5, blt, s0, s1)          // -1 < 1 signed
    NOT_TAKEN(6, blt, s1, s0)
    NOT_TAKEN(7, blt, s1, s1)
    TAKEN(8, blt, s2, s3)          // most negative < most positive
    TAKEN(9, bge, s1, s0)
    TAKEN(10, bge, s1, s1)         // equal counts as >=
    NOT_TAKEN(11, bge, s0, s1)
    TAKEN(12, bltu, s1, s0)        // 1 < 0xffffffff unsigned
    NOT_TAKEN(13, bltu, s0, s1)
    NOT_TAKEN(14, bltu, s1, s1)
    TAKEN(15, bltu, s3, s2)
    TAKEN(16, bgeu, s0, s1)
    TAKEN(17, bgeu, zero, zero)
    NOT_TAKEN(18, bgeu, s1, s0)

    // Backward branch loop: sum 1..10 = 55.
    li a0, 0
    li a1, 10
2:  add a0, a0, a1
    addi a1, a1, -1
    bnez a1, 2b
    CHECK(19, a0, 55)

    // Instructions after a taken branch must not execute.
    li a2, 0
    beq zero, zero, 3f
    li a2, 1
    li a2, 2
3:  CHECK(20, a2, 0)
    TEST_END
RVTEST_CODE_END
