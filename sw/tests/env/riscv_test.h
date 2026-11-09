// Test environment for this CPU: replaces riscv-tests' env/p/riscv_test.h.
//
// The stock environment sets up CSRs, traps and a tohost word, none of which
// this RV32I core implements. Here a test simply:
//   * starts at _start (address 0), clears x1-x31 (the register file has no reset),
//   * reports by storing a word to 0xF000_0000: 1 = pass,
//     (test_number << 1) | 1 = fail (0xFFFF_FFFF if the test number was 0),
//   * then executes ECALL, which stops the CPU.
// Used by the official rv32ui tests and by the directed tests in sw/tests/.
#ifndef RVC_RISCV_TEST_H
#define RVC_RISCV_TEST_H

#define TESTNUM gp
#define RVC_RESULT_ADDR 0xF0000000

#define RVTEST_RV32U .macro init; .endm
#define RVTEST_RV64U RVTEST_RV32U

#define INIT_XREG \
    li x1, 0;  li x2, 0;  li x3, 0;  li x4, 0;  li x5, 0;  li x6, 0;  \
    li x7, 0;  li x8, 0;  li x9, 0;  li x10, 0; li x11, 0; li x12, 0; \
    li x13, 0; li x14, 0; li x15, 0; li x16, 0; li x17, 0; li x18, 0; \
    li x19, 0; li x20, 0; li x21, 0; li x22, 0; li x23, 0; li x24, 0; \
    li x25, 0; li x26, 0; li x27, 0; li x28, 0; li x29, 0; li x30, 0; \
    li x31, 0

#define RVTEST_CODE_BEGIN \
    .section .text.init, "ax", @progbits; \
    .align 2; \
    .globl _start; \
_start: \
    INIT_XREG; \
    init

#define RVTEST_CODE_END \
    unimp

#define RVTEST_PASS \
    fence; \
    li t5, RVC_RESULT_ADDR; \
    li t6, 1; \
    sw t6, 0(t5); \
    ecall

#define RVTEST_FAIL \
    fence; \
    bnez TESTNUM, 9f; \
    li TESTNUM, -1; \
9:  slli t6, TESTNUM, 1; \
    ori t6, t6, 1; \
    li t5, RVC_RESULT_ADDR; \
    sw t6, 0(t5); \
    ecall

#define EXTRA_DATA

#define RVTEST_DATA_BEGIN \
    EXTRA_DATA; \
    .data; \
    .align 4; \
    .global begin_signature; \
begin_signature:

#define RVTEST_DATA_END \
    .align 4; \
    .global end_signature; \
end_signature:

#endif
