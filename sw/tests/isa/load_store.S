// Loads and stores: every size at every legal offset, sign and zero
// extension, negative offsets, and a load right after a store.
#include "riscv_test.h"
#include "check.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN
    la s0, buf

    li a1, 0x8070ff01
    sw a1, 0(s0)
    lw a0, 0(s0);   CHECK(1,  a0, 0x8070ff01)
    lb a0, 0(s0);   CHECK(2,  a0, 0x00000001)
    lb a0, 1(s0);   CHECK(3,  a0, 0xffffffff)
    lb a0, 2(s0);   CHECK(4,  a0, 0x00000070)
    lb a0, 3(s0);   CHECK(5,  a0, 0xffffff80)
    lbu a0, 1(s0);  CHECK(6,  a0, 0x000000ff)
    lbu a0, 3(s0);  CHECK(7,  a0, 0x00000080)
    lh a0, 0(s0);   CHECK(8,  a0, 0xffffff01)
    lh a0, 2(s0);   CHECK(9,  a0, 0xffff8070)
    lhu a0, 0(s0);  CHECK(10, a0, 0x0000ff01)
    lhu a0, 2(s0);  CHECK(11, a0, 0x00008070)

    // Byte stores touch exactly one lane.
    sw zero, 4(s0)
    li a1, 0x123456aa
    sb a1, 4(s0)
    lw a0, 4(s0);   CHECK(12, a0, 0x000000aa)
    sb a1, 5(s0)
    sb a1, 6(s0)
    sb a1, 7(s0)
    lw a0, 4(s0);   CHECK(13, a0, 0xaaaaaaaa)
    li a1, 0x55
    sb a1, 6(s0)
    lw a0, 4(s0);   CHECK(14, a0, 0xaa55aaaa)

    // Halfword stores touch exactly two lanes.
    li a1, 0xdeadbeef
    sh a1, 4(s0)
    lw a0, 4(s0);   CHECK(15, a0, 0xaa55beef)
    sh a1, 6(s0)
    lw a0, 4(s0);   CHECK(16, a0, 0xbeefbeef)

    // Negative offsets, and the neighbours are untouched.
    addi s1, s0, 16
    li a1, 0x11223344
    sw a1, -8(s1)
    lw a0, 8(s0);   CHECK(17, a0, 0x11223344)
    lw a0, 4(s0);   CHECK(18, a0, 0xbeefbeef)
    lw a0, 12(s0);  CHECK(19, a0, 0x0badf00d)
    lbu a0, -5(s1); CHECK(20, a0, 0x11)

    // Store then dependent load then use, back to back.
    li a1, 41
    sw a1, 12(s0)
    lw a2, 12(s0)
    addi a2, a2, 1; CHECK(21, a2, 42)

    // A load into x0 has no effect.
    lw zero, 0(s0); CHECK(22, zero, 0)

    // Data placed by the linker (in .data) is readable.
    la s2, table
    lw a0, 0(s2);   CHECK(23, a0, 0xcafef00d)
    lhu a0, 4(s2);  CHECK(24, a0, 0x1234)
    TEST_END
RVTEST_CODE_END

    .data
    .align 4
buf:
    .word 0, 0, 0, 0x0badf00d
table:
    .word 0xcafef00d
    .half 0x1234, 0x5678
