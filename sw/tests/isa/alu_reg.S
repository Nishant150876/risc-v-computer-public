// Register-register ALU: ADD SUB AND OR XOR SLL SRL SRA SLT SLTU.
// Edge values, shift amounts taken from rs2[4:0] only, rd = x0, rd = rs.
#include "riscv_test.h"
#include "check.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN
    li s0, 0x7fffffff
    li s1, 0x80000000
    li s2, -1
    li s3, 1

    add a0, s0, s3;   CHECK(1,  a0, 0x80000000)   // signed overflow wraps
    add a0, s2, s3;   CHECK(2,  a0, 0)
    sub a0, s1, s3;   CHECK(3,  a0, 0x7fffffff)
    sub a0, zero, s3; CHECK(4,  a0, -1)
    and a0, s0, s2;   CHECK(5,  a0, 0x7fffffff)
    or  a0, s0, s1;   CHECK(6,  a0, -1)
    xor a0, s2, s0;   CHECK(7,  a0, 0x80000000)

    li a1, 31
    sll a0, s3, a1;   CHECK(8,  a0, 0x80000000)
    srl a0, s1, a1;   CHECK(9,  a0, 1)
    sra a0, s1, a1;   CHECK(10, a0, -1)
    li a1, 32                                      // only rs2[4:0] counts: shift by 0
    sll a0, s3, a1;   CHECK(11, a0, 1)
    li a1, 0xffffffe4                              // [4:0] = 4
    srl a0, s1, a1;   CHECK(12, a0, 0x08000000)
    sra a0, s1, a1;   CHECK(13, a0, 0xf8000000)

    slt  a0, s1, s0;  CHECK(14, a0, 1)             // min < max signed
    sltu a0, s1, s0;  CHECK(15, a0, 0)             // but not unsigned
    slt  a0, s2, s3;  CHECK(16, a0, 1)             // -1 < 1
    sltu a0, s2, s3;  CHECK(17, a0, 0)             // 0xffffffff > 1
    slt  a0, s3, s3;  CHECK(18, a0, 0)
    sltu a0, zero, s3; CHECK(19, a0, 1)

    add zero, s2, s2                               // writes to x0 are dropped
    add a0, zero, zero; CHECK(20, a0, 0)
    li a2, 5
    add a2, a2, a2;   CHECK(21, a2, 10)            // rd = rs1 = rs2
    sub a2, a2, a2;   CHECK(22, a2, 0)

    // Dependent chain: each result feeds the next instruction.
    li a3, 3
    add a3, a3, a3
    add a3, a3, a3
    sll a3, a3, s3
    xor a3, a3, s2;   CHECK(23, a3, ~24)

    TEST_END
RVTEST_CODE_END
