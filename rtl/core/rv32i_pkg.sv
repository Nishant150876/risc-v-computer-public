`timescale 1ns/1ps

// Shared Phase 1 and Phase 2 contracts. This package contains no architectural state.
package rv32i_pkg;
    typedef enum logic [6:0] {
        OPCODE_LUI      = 7'b0110111,
        OPCODE_AUIPC    = 7'b0010111,
        OPCODE_JAL      = 7'b1101111,
        OPCODE_JALR     = 7'b1100111,
        OPCODE_BRANCH   = 7'b1100011,
        OPCODE_LOAD     = 7'b0000011,
        OPCODE_STORE    = 7'b0100011,
        OPCODE_OP_IMM   = 7'b0010011,
        OPCODE_OP       = 7'b0110011,
        OPCODE_MISC_MEM = 7'b0001111,
        OPCODE_SYSTEM   = 7'b1110011
    } opcode_t;

    typedef enum logic [6:0] {
        FUNCT7_BASE = 7'b0000000, FUNCT7_ALT = 7'b0100000
    } funct7_t;
    typedef enum logic [31:0] {
        INSTR_ECALL = 32'h0000_0073, INSTR_EBREAK = 32'h0010_0073
    } system_instr_t;

    typedef enum logic [3:0] {
        ALU_ADD, ALU_SUB, ALU_AND, ALU_OR, ALU_XOR,
        ALU_SLL, ALU_SRL, ALU_SRA, ALU_SLT, ALU_SLTU
    } alu_op_t;

    typedef enum logic [1:0] { OPA_RS1, OPA_PC, OPA_ZERO } op_a_sel_t;
    typedef enum logic { OPB_RS2, OPB_IMM } op_b_sel_t;
    typedef enum logic [2:0] { IMM_NONE, IMM_I, IMM_S, IMM_B, IMM_U, IMM_J } imm_sel_t;
    typedef enum logic [2:0] {
        BR_NONE, BR_EQ, BR_NE, BR_LT, BR_GE, BR_LTU, BR_GEU
    } branch_t;
    typedef enum logic [1:0] { JUMP_NONE, JUMP_JAL, JUMP_JALR } jump_t;
    typedef enum logic [1:0] { WB_ALU, WB_MEM, WB_PC4 } wb_sel_t;
    typedef enum logic [1:0] { MEM_BYTE, MEM_HALF, MEM_WORD } mem_size_t;
    typedef enum logic [1:0] { HALT_NONE, HALT_ECALL, HALT_EBREAK } halt_t;

    typedef struct packed {
        alu_op_t   alu_op;
        op_a_sel_t op_a_sel;
        op_b_sel_t op_b_sel;
        imm_sel_t  imm_sel;
        branch_t   branch;
        jump_t     jump;
        wb_sel_t   wb_sel;
        logic      reg_write;
        logic      uses_rs1;
        logic      uses_rs2;
        mem_size_t mem_size;
        logic      mem_read;
        logic      mem_write;
        logic      mem_unsigned;
        halt_t     halt;
        logic      illegal;
    } control_t;

    // Zero encodings deliberately select ADD/rs1/rs2 and no side effects.
    // A future valid/retirement signal is separate from this decode record.
    function automatic control_t nop_control();
        return '0;
    endfunction

    function automatic control_t illegal_control();
        control_t disabled;
        disabled = '0;
        disabled.illegal = 1'b1;
        return disabled;
    endfunction

    // ---- Phase 2: reset, stop and retirement contracts ----------------------
    // Reset PC is next_pc's RESET_PC parameter (0x0000_0000, start of RAM).

    // Why the CPU stopped. ECALL/EBREAK retire first; every other cause is a
    // fault: the faulting instruction does NOT retire and changes no state.
    typedef enum logic [2:0] {
        STOP_NONE,
        STOP_ECALL,
        STOP_EBREAK,
        STOP_ILLEGAL,          // decoder.illegal
        STOP_MISALIGNED_FETCH, // taken branch/jump target not 4-byte aligned
        STOP_MISALIGNED_LOAD,  // LH/LHU not 2-aligned, LW not 4-aligned
        STOP_MISALIGNED_STORE  // SH not 2-aligned, SW not 4-aligned
    } stop_cause_t;

    // One record per retired instruction, valid for exactly one clock. This is
    // the architectural boundary shared by tests, counters, trace and debug.
    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] instr;
        logic [31:0] next_pc;   // PC of the next instruction to execute
        logic        rd_we;     // false for rd = x0 and for no-write instructions
        logic [4:0]  rd;
        logic [31:0] rd_wdata;
        logic        mem_re;
        logic [3:0]  mem_wstrb; // byte lanes written; 0 when not a store
        logic [31:0] mem_addr;  // byte address of the load/store
        logic [31:0] mem_wdata; // store data already shifted to its lanes
    } retire_t;
    // Optional single-cycle debug boundary. Requests are sampled at retirement
    // edges, never used to gate a half-completed falling-edge memory access.
    typedef struct packed {
        logic halt, resume, step, bypass_break;
        logic reg_we;
        logic [4:0] reg_addr;
        logic [31:0] reg_wdata;
        logic [1:0] breakpoint_enable;
        logic [31:0] breakpoint0,breakpoint1;
        logic alu_test;
        alu_op_t alu_op;
        logic [31:0] alu_a,alu_b;
    } cpu_debug_control_t;
    typedef struct packed {
        logic stopped,breakpoint,last_pc_valid,reset_held;
        logic [31:0] next_pc,last_pc,reg_rdata,alu_result;
    } cpu_debug_status_t;

    // ---- Phase 5: pipeline registers and hazard contracts -------------------
    // Forwarding source for one EX operand. FWD_MEM takes the EX/MEM result,
    // FWD_WB the value being written back. Write-back to ID is the register
    // file bypass. x0 is never a forwarding source.
    typedef enum logic [1:0] { FWD_NONE, FWD_MEM, FWD_WB } fwd_sel_t;

    // IF/ID: the instruction itself is the block RAM output register.
    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
    } if_id_t;

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] instr;
        control_t    ctrl;
        logic [31:0] imm;
        logic [31:0] rs1_data;
        logic [31:0] rs2_data;
    } id_ex_t;

    // EX/MEM and MEM/WB carry the same record. stop is STOP_NONE, a halt
    // (ECALL/EBREAK retire) or a fault (does not retire, has no side effects).
    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] instr;
        logic [31:0] next_pc;
        logic        rd_we;     // never set for x0 or for a fault
        logic [4:0]  rd;
        logic [31:0] result;    // ALU result or pc + 4
        wb_sel_t     wb_sel;
        logic        mem_re;
        logic [3:0]  mem_wstrb;
        logic [31:0] mem_addr;
        logic [31:0] mem_wdata;
        mem_size_t   mem_size;
        logic        mem_unsigned;
        stop_cause_t stop;
    } ex_mem_t;
    typedef ex_mem_t mem_wb_t;
endpackage
