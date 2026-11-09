// cpu_tb: +expect_stop=MISALIGNED_STORE +expect=sw/tests/faults/fault_misaligned_store.expect
// Alignment contract: SB anywhere and SH on even addresses are fine; a SW at
// addr % 4 = 2 stops the CPU and writes no byte.
#include "riscv_test.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN
    li s0, 0x3000
    sw zero, 4(s0)         // initialize lanes not touched by the byte/half stores
    sw zero, 8(s0)
    li a0, 0x11223344
    sw a0, 0(s0)
    li a1, 0x55
    sb a1, 5(s0)            // byte store at an odd address: legal
    li a1, 0x6677
    sh a1, 10(s0)           // half store at addr % 4 = 2: legal
    li a2, 0xdeadbeef
    sw a2, 2(s0)            // misaligned word store: stops here
    sw a2, 0(s0)
    RVTEST_PASS
RVTEST_CODE_END
