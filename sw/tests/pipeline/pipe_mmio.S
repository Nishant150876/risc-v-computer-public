// cpu_tb: +uart_console +uart_input=4b +uart_expect=sw/tests/pipeline/pipe_mmio.expect
// Phase 5: MMIO reads with side effects in the pipeline. A UART RX read pops
// the FIFO, so only a valid instruction in MEM may issue it, exactly once:
// never from the wrong path after a taken jump, never twice across a
// load-use stall. One byte ('K') is typed; it must be read exactly once.
#include "riscv_test.h"
#include "check.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN
    li s0, 0x80000000
1:  lw t0, 0x14(s0)                 // wait for RX available
    andi t0, t0, 2
    beqz t0, 1b

    // Wrong-path RX reads after a taken jump must be flushed before MEM.
    li TESTNUM, 1
    j 2f
    lw t1, 0x18(s0)
    lw t1, 0x18(s0)
2:  lw t0, 0x14(s0)
    andi t0, t0, 2
    beqz t0, fail                   // the byte is still queued

    // RX read followed by its consumer: the stall must not repeat the read.
    lw a1, 0x18(s0)
    addi a2, a1, 0;                 CHECK(2, a2, 0x4b)
    lw t0, 0x14(s0)
    andi t0, t0, 2;                 CHECK(3, t0, 0)          // FIFO empty: popped once
    lw t0, 0x18(s0);                CHECK(4, t0, 0)          // empty RX reads zero

    // Echo it (load-use into store data was covered above; this is a plain store).
    sw a1, 0x10(s0)
3:  lw t0, 0x14(s0)                 // wait until the byte has left TX
    andi t0, t0, 1
    bnez t0, 3b
    li a0, 0
    j pass

    TEST_END
RVTEST_CODE_END
