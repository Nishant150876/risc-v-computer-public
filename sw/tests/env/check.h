// Helpers for the directed tests in sw/tests/. Include after riscv_test.h.
#ifndef RVC_CHECK_H
#define RVC_CHECK_H

// Fail test n unless register reg equals value. Uses t6 as scratch, so do
// not CHECK t6 itself.
#define CHECK(n, reg, value) \
    li TESTNUM, n; \
    li t6, value; \
    bne reg, t6, fail

// Every directed test ends with this: falls into pass, or branches to fail.
#define TEST_END \
pass: \
    RVTEST_PASS; \
fail: \
    RVTEST_FAIL

#endif
