// LUI and AUIPC. AUIPC results are compared against link-time addresses
// built with LUI + ADDI only, so the check does not depend on AUIPC itself.
#include "riscv_test.h"
#include "check.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN
    lui a0, 0x12345;      CHECK(1, a0, 0x12345000)
    lui a0, 0xfffff;      CHECK(2, a0, 0xfffff000)
    lui a0, 0;            CHECK(3, a0, 0)
    lui a0, 0x80000
    addi a0, a0, -1;      CHECK(4, a0, 0x7fffffff)

p1: auipc a1, 0
    lui t0, %hi(p1)
    addi t0, t0, %lo(p1)
    li TESTNUM, 5
    bne a1, t0, fail

p2: auipc a1, 0x1
    lui t0, %hi(p2 + 0x1000)
    addi t0, t0, %lo(p2 + 0x1000)
    li TESTNUM, 6
    bne a1, t0, fail

p3: auipc a1, 0xfffff       // pc - 0x1000 wraps around address 0
    lui t0, %hi(p3 - 0x1000)
    addi t0, t0, %lo(p3 - 0x1000)
    li TESTNUM, 7
    bne a1, t0, fail

    lui zero, 0x1;        CHECK(8, zero, 0)
    TEST_END
RVTEST_CODE_END
