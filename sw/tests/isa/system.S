// cpu_tb: +expect_stop=EBREAK +expect=sw/tests/isa/system.expect
// FENCE is a no-op; EBREAK stops the CPU just like ECALL (project policy).
#include "riscv_test.h"
#include "check.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN
    li s0, 0x3000
    li a1, 0x1234
    sw a1, 0(s0)
    li a0, 7
    fence
    fence rw, rw
    fence.tso
    addi a0, a0, 1
    CHECK(1, a0, 8)
    // Report pass, then stop with EBREAK instead of ECALL.
    li t5, RVC_RESULT_ADDR
    li t6, 1
    sw t6, 0(t5)
    ebreak
    // The next fetched instruction is a store: even while decoded after
    // EBREAK it must not write. This exposes a missing commit/halt gate.
    sw zero, 0(s0)
    j fail
fail:
    RVTEST_FAIL
RVTEST_CODE_END
