// Immediate ALU: ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI.
// 12-bit immediates are sign-extended, including for SLTIU and the logic ops.
#include "riscv_test.h"
#include "check.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN
    li s1, 0x80000000
    li s2, -1

    addi a0, zero, 2047;  CHECK(1,  a0, 2047)
    addi a0, zero, -2048; CHECK(2,  a0, -2048)
    addi a0, s2, 1;       CHECK(3,  a0, 0)
    addi a0, s1, -1;      CHECK(4,  a0, 0x7fffffff)

    slti  a0, s2, 0;      CHECK(5,  a0, 1)
    slti  a0, zero, -1;   CHECK(6,  a0, 0)
    sltiu a0, zero, -1;   CHECK(7,  a0, 1)         // 0 < 0xffffffff
    sltiu a0, s2, -1;     CHECK(8,  a0, 0)
    sltiu a0, zero, 1;    CHECK(9,  a0, 1)         // seqz idiom

    xori a0, zero, -1;    CHECK(10, a0, -1)        // not
    xori a0, s2, 0x7ff;   CHECK(11, a0, 0xfffff800)
    ori  a0, zero, -2048; CHECK(12, a0, 0xfffff800)
    andi a0, s2, 0x7ff;   CHECK(13, a0, 0x7ff)
    andi a0, s2, -2048;   CHECK(14, a0, 0xfffff800)

    li a1, 1
    slli a0, a1, 0;       CHECK(15, a0, 1)
    slli a0, a1, 31;      CHECK(16, a0, 0x80000000)
    srli a0, s1, 31;      CHECK(17, a0, 1)
    srai a0, s1, 31;      CHECK(18, a0, -1)
    srai a0, s1, 0;       CHECK(19, a0, 0x80000000)
    li a2, 0x40000000
    srai a0, a2, 30;      CHECK(20, a0, 1)

    addi zero, zero, 123                           // nop-like write to x0
    CHECK(21, zero, 0)
    TEST_END
RVTEST_CODE_END
