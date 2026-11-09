`timescale 1ns/1ps

module decoder (
    input  logic [31:0]         instr,
    output rv32i_pkg::control_t ctrl
);
    import rv32i_pkg::*;

    always_comb begin
        ctrl = nop_control();
        case (instr[6:0])
            OPCODE_LUI: begin
                ctrl.reg_write = 1'b1;
                ctrl.op_a_sel = OPA_ZERO;
                ctrl.op_b_sel = OPB_IMM;
                ctrl.imm_sel = IMM_U;
            end
            OPCODE_AUIPC: begin
                ctrl.reg_write = 1'b1;
                ctrl.op_a_sel = OPA_PC;
                ctrl.op_b_sel = OPB_IMM;
                ctrl.imm_sel = IMM_U;
            end
            OPCODE_JAL: begin
                ctrl.reg_write = 1'b1;
                ctrl.op_a_sel = OPA_PC;
                ctrl.op_b_sel = OPB_IMM;
                ctrl.imm_sel = IMM_J;
                ctrl.jump = JUMP_JAL;
                ctrl.wb_sel = WB_PC4;
            end
            OPCODE_JALR: begin
                ctrl.reg_write = 1'b1;
                ctrl.uses_rs1 = 1'b1;
                ctrl.op_b_sel = OPB_IMM;
                ctrl.imm_sel = IMM_I;
                ctrl.jump = JUMP_JALR;
                ctrl.wb_sel = WB_PC4;
                ctrl.illegal = instr[14:12] != 3'b000;
            end
            OPCODE_BRANCH: begin
                ctrl.uses_rs1 = 1'b1;
                ctrl.uses_rs2 = 1'b1;
                ctrl.op_a_sel = OPA_PC;
                ctrl.op_b_sel = OPB_IMM;
                ctrl.imm_sel = IMM_B;
                case (instr[14:12])
                    3'b000: ctrl.branch = BR_EQ;
                    3'b001: ctrl.branch = BR_NE;
                    3'b100: ctrl.branch = BR_LT;
                    3'b101: ctrl.branch = BR_GE;
                    3'b110: ctrl.branch = BR_LTU;
                    3'b111: ctrl.branch = BR_GEU;
                    default: ctrl.illegal = 1'b1;
                endcase
            end
            OPCODE_LOAD: begin
                ctrl.reg_write = 1'b1;
                ctrl.uses_rs1 = 1'b1;
                ctrl.op_b_sel = OPB_IMM;
                ctrl.imm_sel = IMM_I;
                ctrl.wb_sel = WB_MEM;
                ctrl.mem_read = 1'b1;
                case (instr[14:12])
                    3'b000: ctrl.mem_size = MEM_BYTE;
                    3'b001: ctrl.mem_size = MEM_HALF;
                    3'b010: ctrl.mem_size = MEM_WORD;
                    3'b100: begin
                        ctrl.mem_size = MEM_BYTE;
                        ctrl.mem_unsigned = 1'b1;
                    end
                    3'b101: begin
                        ctrl.mem_size = MEM_HALF;
                        ctrl.mem_unsigned = 1'b1;
                    end
                    default: ctrl.illegal = 1'b1;
                endcase
            end
            OPCODE_STORE: begin
                ctrl.uses_rs1 = 1'b1;
                ctrl.uses_rs2 = 1'b1;
                ctrl.op_b_sel = OPB_IMM;
                ctrl.imm_sel = IMM_S;
                ctrl.mem_write = 1'b1;
                case (instr[14:12])
                    3'b000: ctrl.mem_size = MEM_BYTE;
                    3'b001: ctrl.mem_size = MEM_HALF;
                    3'b010: ctrl.mem_size = MEM_WORD;
                    default: ctrl.illegal = 1'b1;
                endcase
            end
            OPCODE_OP_IMM: begin
                ctrl.reg_write = 1'b1;
                ctrl.uses_rs1 = 1'b1;
                ctrl.op_b_sel = OPB_IMM;
                ctrl.imm_sel = IMM_I;
                case (instr[14:12])
                    3'b000: ctrl.alu_op = ALU_ADD;
                    3'b010: ctrl.alu_op = ALU_SLT;
                    3'b011: ctrl.alu_op = ALU_SLTU;
                    3'b100: ctrl.alu_op = ALU_XOR;
                    3'b110: ctrl.alu_op = ALU_OR;
                    3'b111: ctrl.alu_op = ALU_AND;
                    3'b001: begin
                        ctrl.alu_op = ALU_SLL;
                        ctrl.illegal = instr[31:25] != FUNCT7_BASE;
                    end
                    3'b101: begin
                        case (instr[31:25])
                            FUNCT7_BASE: ctrl.alu_op = ALU_SRL;
                            FUNCT7_ALT: ctrl.alu_op = ALU_SRA;
                            default: ctrl.illegal = 1'b1;
                        endcase
                    end
                    default: ctrl.illegal = 1'b1;
                endcase
            end
            OPCODE_OP: begin
                ctrl.reg_write = 1'b1;
                ctrl.uses_rs1 = 1'b1;
                ctrl.uses_rs2 = 1'b1;
                case ({instr[31:25], instr[14:12]})
                    {FUNCT7_BASE, 3'b000}: ctrl.alu_op = ALU_ADD;
                    {FUNCT7_ALT,  3'b000}: ctrl.alu_op = ALU_SUB;
                    {FUNCT7_BASE, 3'b001}: ctrl.alu_op = ALU_SLL;
                    {FUNCT7_BASE, 3'b010}: ctrl.alu_op = ALU_SLT;
                    {FUNCT7_BASE, 3'b011}: ctrl.alu_op = ALU_SLTU;
                    {FUNCT7_BASE, 3'b100}: ctrl.alu_op = ALU_XOR;
                    {FUNCT7_BASE, 3'b101}: ctrl.alu_op = ALU_SRL;
                    {FUNCT7_ALT,  3'b101}: ctrl.alu_op = ALU_SRA;
                    {FUNCT7_BASE, 3'b110}: ctrl.alu_op = ALU_OR;
                    {FUNCT7_BASE, 3'b111}: ctrl.alu_op = ALU_AND;
                    default: ctrl.illegal = 1'b1;
                endcase
            end
            OPCODE_MISC_MEM: begin
                // FENCE is an intentional no-op in this in-order environment.
                // Base FENCE ignores rd/rs1/fm/pred/succ. FENCE.I is not RV32I.
                ctrl.illegal = instr[14:12] != 3'b000;
            end
            OPCODE_SYSTEM: begin
                // These are project halt requests, not privileged trap support.
                case (instr)
                    INSTR_ECALL:  ctrl.halt = HALT_ECALL;
                    INSTR_EBREAK: ctrl.halt = HALT_EBREAK;
                    default: ctrl.illegal = 1'b1;
                endcase
            end
            default: ctrl.illegal = 1'b1;
        endcase

        // Never leak a partly decoded write, branch, jump or halt on an error.
        if (ctrl.illegal) ctrl = illegal_control();
    end
endmodule
