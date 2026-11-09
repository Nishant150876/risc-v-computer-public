// Phase 5 hazard zoo. Every pipeline hazard case at an exact distance, so a
// missing or wrong forward, stall or flush gives a wrong value. The same
// program runs on cpu_single (cpu_tb), cpu_pipe (cpu_pipe_tb) and both in
// lockstep (lockstep_tb). "Distance n" means the consumer is the n-th
// instruction after the producer; nothing else sits between them.
//
// Covered: ALU dependencies at distance 1, 2, 3 and 4 on rs1, rs2 and both;
// youngest-producer priority; load-use on rs1/rs2, load-use into a branch
// and into JALR, load then dependent load (pointer chase), load at distance
// 2 and 3; load then store of the same register (data and address); store
// data forwarded at distance 1/2/3; store then load of the same word;
// branches on just-computed and just-loaded values, taken and not taken;
// back-to-back taken branches; JAL/JALR with the return address used right
// away, jalr ra, 0(ra); wrong-path stores, register writes, ECALL and an
// illegal word that must all be flushed; and x0 as a destination (ALU, LUI,
// load, JAL), which must never be forwarded.
#include "riscv_test.h"
#include "check.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN
    la s0, buf

    // ---- ALU -> ALU, distance 1..4 --------------------------------------
    li a1, 5
    addi a0, a1, 1;                  CHECK(1, a0, 6)        // rs1, distance 1
    li a1, 7
    nop
    addi a0, a1, 1;                  CHECK(2, a0, 8)        // rs1, distance 2
    li a1, 9
    nop
    nop
    addi a0, a1, 1;                  CHECK(3, a0, 10)       // rs1, distance 3 (regfile bypass)
    li a1, 11
    nop
    nop
    nop
    addi a0, a1, 1;                  CHECK(4, a0, 12)       // distance 4: no hazard
    li a1, 100
    li a2, 3
    sub a0, a1, a2;                  CHECK(5, a0, 97)       // rs2 distance 1, rs1 distance 2
    li a2, 3
    li a1, 100
    sub a0, a1, a2;                  CHECK(6, a0, 97)       // rs1 distance 1, rs2 distance 2
    li a1, 21
    add a0, a1, a1;                  CHECK(7, a0, 42)       // both sources, distance 1
    li a1, 1
    li a1, 2
    li a1, 3
    add a0, a1, zero;                CHECK(8, a0, 3)        // youngest producer wins
    li a1, 1
    li a1, 2
    nop
    add a0, a1, zero;                CHECK(9, a0, 2)        // MEM vs WB: youngest wins
    li a1, 0x10
    slli a1, a1, 4
    addi a1, a1, 1
    xor a0, a1, a1
    or a0, a0, a1;                   CHECK(10, a0, 0x101)   // a chain of distance-1 uses
    lui a1, 0x12345
    addi a0, a1, 0x678;              CHECK(11, a0, 0x12345678)
    auipc a1, 0
    sub a0, a1, a1;                  CHECK(12, a0, 0)

    // ---- loads ------------------------------------------------------------
    li a1, 0x1234
    sw a1, 0(s0)
    lw a2, 0(s0)
    addi a0, a2, 1;                  CHECK(20, a0, 0x1235)  // load-use, rs1
    lw a2, 0(s0)
    sub a0, zero, a2;                CHECK(21, a0, -0x1234) // load-use, rs2
    lw a2, 0(s0)
    nop
    addi a0, a2, 2;                  CHECK(22, a0, 0x1236)  // load, distance 2
    lw a2, 0(s0)
    nop
    nop
    addi a0, a2, 3;                  CHECK(23, a0, 0x1237)  // load, distance 3
    lw a2, 0(s0)
    add a0, a2, a2;                  CHECK(24, a0, 0x2468)  // load-use, both sources
    li a2, 0
    lb a2, 0(s0)
    addi a0, a2, 0;                  CHECK(25, a0, 0x34)    // byte load-use
    // Pointer chase: the next load's address is the previous load's data.
    addi a1, s0, 8
    sw a1, 4(s0)
    li a3, 0x55aa
    sw a3, 8(s0)
    lw a2, 4(s0)
    lw a0, 0(a2);                    CHECK(26, a0, 0x55aa)
    // Load then store of the same register: store data and store address.
    li a1, 0x0badcafe
    sw a1, 12(s0)
    lw a2, 12(s0)
    sw a2, 16(s0)                                           // load-use on store data
    lw a0, 16(s0);                   CHECK(27, a0, 0x0badcafe)
    addi a1, s0, 20
    sw a1, 24(s0)
    lw a2, 24(s0)
    sw a3, 0(a2)                                            // load-use on store address
    lw a0, 20(s0);                   CHECK(28, a0, 0x55aa)
    lw a2, 12(s0)
    nop
    sw a2, 28(s0)                                           // load, then store at distance 2
    lw a0, 28(s0);                   CHECK(29, a0, 0x0badcafe)
    // A load-use stall must not repeat or drop the load's own side effects.
    li a1, 1
    sw a1, 32(s0)
    lw a2, 32(s0)
    addi a2, a2, 1
    sw a2, 32(s0)
    lw a2, 32(s0)
    addi a2, a2, 1
    sw a2, 32(s0)
    lw a0, 32(s0);                   CHECK(30, a0, 3)

    // ---- store data forwarding ---------------------------------------------
    li a1, 0x111
    sw a1, 36(s0)                                           // distance 1
    lw a0, 36(s0);                   CHECK(31, a0, 0x111)
    li a1, 0x222
    nop
    sw a1, 36(s0)                                           // distance 2
    lw a0, 36(s0);                   CHECK(32, a0, 0x222)
    li a1, 0x333
    nop
    nop
    sw a1, 36(s0)                                           // distance 3
    lw a0, 36(s0);                   CHECK(33, a0, 0x333)
    li a1, 0x44
    sb a1, 37(s0)                                           // byte lane, distance 1
    lw a0, 36(s0);                   CHECK(34, a0, 0x4433)
    addi a4, s0, 40
    li a1, 0x777
    sw a1, 0(a4)                                            // address and data both forwarded
    lw a0, 40(s0);                   CHECK(35, a0, 0x777)

    // ---- branches on just-computed values ----------------------------------
    li TESTNUM, 40
    li a1, 3
    li a2, 3
    bne a1, a2, fail                                        // distance 1/2, not taken
    li a1, 4
    beq a1, a2, fail                                        // distance 1, not taken
    li a2, 4
    beq a1, a2, 1f                                          // distance 1, taken
    j fail
1:  li TESTNUM, 41
    lw a2, 0(s0)
    bne a2, a1, 2f                                          // load-use into a branch, taken
    j fail
2:  li TESTNUM, 42
    lw a2, 0(s0)
    nop
    beq a2, zero, fail                                      // load at distance 2, not taken
    // Wrong-path side effects after a taken branch must be flushed.
    li TESTNUM, 43
    sw zero, 44(s0)
    li a0, 0
    li a1, 1
    beq a1, a1, 3f
    sw a1, 44(s0)                                           // flushed store
    li a0, 99                                               // flushed write
3:  lw a1, 44(s0)
    bne a1, zero, fail
    bne a0, zero, fail
    li TESTNUM, 44
    j 4f
    ecall                                                   // flushed halt
    .word 0                                                 // flushed illegal word
4:  li TESTNUM, 45
    li a0, 0
    beq zero, zero, 5f                                      // back-to-back taken branches
    li a0, 1
5:  beq zero, zero, 6f
    li a0, 2
6:  bne a0, zero, fail
    // A taken branch in the shadow of another taken branch is not executed.
    li TESTNUM, 46
    li a0, 0
    j 7f
    j fail
    j fail
7:  bne a0, zero, fail

    // ---- JAL/JALR: the return address used right away ----------------------
    li TESTNUM, 50
    jal ra, 8f
8:  la a1, 8b
    bne ra, a1, fail                                        // ra at distance 2 (la is 2 ops)
    jal ra, 9f
9:  addi a0, ra, 0                                          // ra at distance 1
    la a1, 9b
    bne a0, a1, fail
    li TESTNUM, 51
    la t0, 10f
    jalr ra, 0(t0)                                          // jalr on a just-computed target
    j fail
10: la a1, 10b - 4
    bne ra, a1, fail
    li TESTNUM, 52
    la t0, 11f
    sw t0, 48(s0)
    lw t1, 48(s0)
    jalr ra, 0(t1)                                          // load-use into JALR
    j fail
11: li TESTNUM, 53
    la ra, 12f
    jalr ra, 0(ra)                                          // rd == rs1
    j fail
12: la a1, 12b - 4
    bne ra, a1, fail
    // Call and return with the link used immediately by the callee.
    li TESTNUM, 54
    li a0, 0
    jal ra, leaf
14: la a1, 14b
    bne a0, a1, fail

    // ---- x0 as a destination: never written, never forwarded --------------
    li a1, 5
    addi zero, a1, 1
    add a0, zero, a1;                CHECK(60, a0, 5)       // distance 1
    addi zero, a1, 1
    nop
    add a0, zero, a1;                CHECK(61, a0, 5)       // distance 2
    addi zero, a1, 1
    nop
    nop
    add a0, zero, a1;                CHECK(62, a0, 5)       // distance 3
    lui zero, 0xfffff
    or a0, zero, zero;               CHECK(63, a0, 0)
    lw zero, 0(s0)
    add a0, zero, zero;              CHECK(64, a0, 0)       // no load-use from x0
    jal zero, 13f
13: add a0, zero, zero;              CHECK(65, a0, 0)
    sw zero, 52(s0)
    lw a0, 52(s0);                   CHECK(66, a0, 0)       // x0 as store data

    j pass

leaf:
    addi a0, ra, 0                                          // ra used at distance 1
    jalr zero, 0(ra)                                        // and again at distance 2

    TEST_END
RVTEST_CODE_END

    .data
    .align 4
buf:
    .fill 16, 4, 0x0badf00d
