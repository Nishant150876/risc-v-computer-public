`timescale 1ns/1ps

// Next-PC selection for the single-cycle CPU (and later the pipeline's EX).
//   sequential:   pc + 4
//   branch, JAL:  pc + imm
//   JALR:         (rs1 + imm) with bit 0 cleared
// Reset forces RESET_PC; hold keeps pc (a fault or a stopped CPU).
// misaligned is set when a taken target is not 4-byte aligned (no C
// extension); the CPU must then stop without retiring the instruction.
module next_pc #(
    parameter logic [31:0] RESET_PC = 32'h0000_0000
) (
    input  logic [31:0]        pc,
    input  logic [31:0]        rs1,
    input  logic [31:0]        imm,
    input  rv32i_pkg::jump_t   jump,
    input  logic               branch_taken,
    input  logic               rst,
    input  logic               hold,
    output logic [31:0]        pc_plus4,
    output logic [31:0]        target,
    output logic               redirect,
    output logic               misaligned,
    output logic [31:0]        next
);
    import rv32i_pkg::*;

    logic [31:0] jalr_sum;
    logic        unused_jalr_bit0;   // JALR clears bit 0 by definition
    assign unused_jalr_bit0 = jalr_sum[0];

    // Separate assignments: hold may depend on misaligned (a fault), so the
    // target logic must not share a process with the final selection.
    assign pc_plus4   = pc + 32'd4;
    assign jalr_sum   = rs1 + imm;
    assign target     = (jump == JUMP_JALR) ? {jalr_sum[31:1], 1'b0} : pc + imm;
    assign redirect   = (jump != JUMP_NONE) || branch_taken;
    assign misaligned = redirect && (|target[1:0]);

    always_comb begin
        if (rst)       next = RESET_PC;
        else if (hold) next = pc;
        else           next = redirect ? target : pc_plus4;
    end
endmodule
