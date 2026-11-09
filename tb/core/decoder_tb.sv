`timescale 1ns/1ps

module decoder_tb;
    import rv32i_pkg::*;

    logic [31:0] instr = '0;
    control_t ctrl;
    logic [31:0] rng = 32'hdec0_2026;
    int unsigned checks = 0;
    alu_op_t arithmetic [0:7] = '{
        ALU_ADD, ALU_SLL, ALU_SLT, ALU_SLTU, ALU_XOR, ALU_SRL, ALU_OR, ALU_AND
    };
    logic [2:0] branch_codes [0:5] = '{3'd0, 3'd1, 3'd4, 3'd5, 3'd6, 3'd7};
    branch_t conditions [0:5] = '{BR_EQ, BR_NE, BR_LT, BR_GE, BR_LTU, BR_GEU};
    logic [2:0] load_codes [0:4] = '{3'd0, 3'd1, 3'd2, 3'd4, 3'd5};
    mem_size_t load_sizes [0:4] = '{MEM_BYTE, MEM_HALF, MEM_WORD, MEM_BYTE, MEM_HALF};

    decoder dut (.instr(instr), .ctrl(ctrl));

    function automatic logic [31:0] random_word();
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        return rng;
    endfunction

    // Expected controls start from literal zero, independently of nop_control.
    function automatic control_t arithmetic_control(input alu_op_t operation, input bit immediate);
        control_t expected;
        expected = '0;
        expected.reg_write = 1'b1;
        expected.uses_rs1 = 1'b1;
        expected.uses_rs2 = !immediate;
        expected.alu_op = operation;
        if (immediate) begin
            expected.op_b_sel = OPB_IMM;
            expected.imm_sel = IMM_I;
        end
        return expected;
    endfunction

    // Name each mismatching control field so a failure points at the bug.
    // Enum values print as numbers; their order is defined in rv32i_pkg.sv.
    task automatic report_field_differences(input control_t expected);
        if (ctrl.alu_op !== expected.alu_op)
            $display("  alu_op: expected %0d, got %0d", expected.alu_op, ctrl.alu_op);
        if (ctrl.op_a_sel !== expected.op_a_sel)
            $display("  op_a_sel: expected %0d, got %0d", expected.op_a_sel, ctrl.op_a_sel);
        if (ctrl.op_b_sel !== expected.op_b_sel)
            $display("  op_b_sel: expected %0d, got %0d", expected.op_b_sel, ctrl.op_b_sel);
        if (ctrl.imm_sel !== expected.imm_sel)
            $display("  imm_sel: expected %0d, got %0d", expected.imm_sel, ctrl.imm_sel);
        if (ctrl.branch !== expected.branch)
            $display("  branch: expected %0d, got %0d", expected.branch, ctrl.branch);
        if (ctrl.jump !== expected.jump)
            $display("  jump: expected %0d, got %0d", expected.jump, ctrl.jump);
        if (ctrl.wb_sel !== expected.wb_sel)
            $display("  wb_sel: expected %0d, got %0d", expected.wb_sel, ctrl.wb_sel);
        if (ctrl.mem_size !== expected.mem_size)
            $display("  mem_size: expected %0d, got %0d", expected.mem_size, ctrl.mem_size);
        if (ctrl.halt !== expected.halt)
            $display("  halt: expected %0d, got %0d", expected.halt, ctrl.halt);
        if ({ctrl.reg_write, ctrl.uses_rs1, ctrl.uses_rs2, ctrl.mem_read, ctrl.mem_write,
             ctrl.mem_unsigned, ctrl.illegal} !==
            {expected.reg_write, expected.uses_rs1, expected.uses_rs2, expected.mem_read,
             expected.mem_write, expected.mem_unsigned, expected.illegal})
            $display("  flags reg_write/uses_rs1/uses_rs2/mem_read/mem_write/mem_unsigned/illegal: expected %b%b%b%b%b%b%b, got %b%b%b%b%b%b%b",
                     expected.reg_write, expected.uses_rs1, expected.uses_rs2, expected.mem_read,
                     expected.mem_write, expected.mem_unsigned, expected.illegal,
                     ctrl.reg_write, ctrl.uses_rs1, ctrl.uses_rs2, ctrl.mem_read,
                     ctrl.mem_write, ctrl.mem_unsigned, ctrl.illegal);
    endtask

    task automatic check_control(
        input logic [31:0] instruction,
        input control_t expected,
        input string description
    );
        instr = instruction;
        #1;
        if (ctrl !== expected) begin
            report_field_differences(expected);
            $fatal(1, "%s instr=%h: expected control %h, got %h",
                   description, instruction, expected, ctrl);
        end
        checks++;
    endtask

    // Opcode/funct literals below are intentionally not taken from the DUT's
    // package opcode constants. Every one of the 40 instructions is checked.
    task automatic check_instruction_set(input logic [31:0] variation);
        logic [4:0] rd, rs1, rs2, shamt;
        logic [11:0] immediate, shift_immediate;
        logic [19:0] upper;
        control_t expected;
        rd = variation[4:0];
        rs1 = variation[9:5];
        rs2 = variation[14:10];
        shamt = variation[19:15];
        immediate = variation[31:20];
        upper = variation[31:12];

        expected = '0;
        expected.reg_write = 1'b1;
        expected.op_a_sel = OPA_ZERO;
        expected.op_b_sel = OPB_IMM;
        expected.imm_sel = IMM_U;
        check_control({upper, rd, 7'h37}, expected, "LUI");
        expected.op_a_sel = OPA_PC;
        check_control({upper, rd, 7'h17}, expected, "AUIPC");
        expected.imm_sel = IMM_J;
        expected.jump = JUMP_JAL;
        expected.wb_sel = WB_PC4;
        check_control({upper, rd, 7'h6f}, expected, "JAL");
        expected.op_a_sel = OPA_RS1;
        expected.uses_rs1 = 1'b1;
        expected.imm_sel = IMM_I;
        expected.jump = JUMP_JALR;
        check_control({immediate, rs1, 3'd0, rd, 7'h67}, expected, "JALR");

        for (int unsigned i = 0; i < 6; i++) begin
            expected = '0;
            expected.uses_rs1 = 1'b1;
            expected.uses_rs2 = 1'b1;
            expected.op_a_sel = OPA_PC;
            expected.op_b_sel = OPB_IMM;
            expected.imm_sel = IMM_B;
            expected.branch = conditions[i];
            check_control({immediate[11:5], rs2, rs1, branch_codes[i], rd, 7'h63},
                          expected, "branch");
        end
        for (int unsigned i = 0; i < 5; i++) begin
            expected = arithmetic_control(ALU_ADD, 1'b1);
            expected.mem_read = 1'b1;
            expected.wb_sel = WB_MEM;
            expected.mem_size = load_sizes[i];
            expected.mem_unsigned = i >= 3;
            check_control({immediate, rs1, load_codes[i], rd, 7'h03}, expected, "load");
        end
        for (int unsigned i = 0; i < 3; i++) begin
            expected = '0;
            expected.uses_rs1 = 1'b1;
            expected.uses_rs2 = 1'b1;
            expected.op_b_sel = OPB_IMM;
            expected.imm_sel = IMM_S;
            expected.mem_write = 1'b1;
            expected.mem_size = mem_size_t'(i);
            check_control({immediate[11:5], rs2, rs1, 3'(i), immediate[4:0], 7'h23},
                          expected, "store");
        end
        for (int unsigned f3 = 0; f3 < 8; f3++) begin
            shift_immediate = (f3 == 1 || f3 == 5) ? {7'd0, shamt} : immediate;
            check_control({shift_immediate, rs1, 3'(f3), rd, 7'h13},
                          arithmetic_control(arithmetic[f3], 1'b1), "OP-IMM");
            check_control({7'd0, rs2, rs1, 3'(f3), rd, 7'h33},
                          arithmetic_control(arithmetic[f3], 1'b0), "OP");
        end
        check_control({7'h20, shamt, rs1, 3'd5, rd, 7'h13},
                      arithmetic_control(ALU_SRA, 1'b1), "SRAI");
        check_control({7'h20, rs2, rs1, 3'd0, rd, 7'h33},
                      arithmetic_control(ALU_SUB, 1'b0), "SUB");
        check_control({7'h20, rs2, rs1, 3'd5, rd, 7'h33},
                      arithmetic_control(ALU_SRA, 1'b0), "SRA");

        expected = '0;
        check_control({immediate, rs1, 3'd0, rd, 7'h0f}, expected, "FENCE, including ignored fields");
        expected.halt = HALT_ECALL;
        check_control(32'h0000_0073, expected, "ECALL halt");
        expected.halt = HALT_EBREAK;
        check_control(32'h0010_0073, expected, "EBREAK halt");
    endtask

    // Independent legality matrix, expressed using numeric ISA fields rather
    // than the decoder's control construction or shared opcode constants.
    function automatic bit legal_encoding(input logic [31:0] instruction);
        logic [2:0] f3;
        logic [6:0] f7;
        f3 = instruction[14:12];
        f7 = instruction[31:25];
        case (instruction[6:0])
            7'h37, 7'h17, 7'h6f: return 1'b1;
            7'h67, 7'h0f: return f3 == 0;
            7'h63: return f3 == 0 || f3 == 1 || f3 >= 4;
            7'h03: return f3 <= 2 || f3 == 4 || f3 == 5;
            7'h23: return f3 <= 2;
            7'h13: return (f3 != 1 && f3 != 5) || f7 == 0 || (f3 == 5 && f7 == 7'h20);
            7'h33: return f7 == 0 || (f7 == 7'h20 && (f3 == 0 || f3 == 5));
            7'h73: return instruction == 32'h0000_0073 || instruction == 32'h0010_0073;
            default: return 1'b0;
        endcase
    endfunction

    task automatic check_classification(input logic [31:0] instruction);
        bit legal;
        control_t disabled;
        legal = legal_encoding(instruction);
        disabled = '0;
        disabled.illegal = 1'b1;
        instr = instruction;
        #1;
        assert (ctrl.illegal === !legal)
            else $fatal(1, "legality instr=%h: expected illegal=%b, got %b", instruction, !legal, ctrl.illegal);
        if (!legal) begin
            assert (ctrl === disabled)
                else $fatal(1, "illegal instruction %h leaked controls: %h", instruction, ctrl);
        end
        checks++;
    endtask

    initial begin
        check_instruction_set(32'd0); // Includes writes to x0 and canonical NOP.
        for (int unsigned trial = 1; trial < 64; trial++) check_instruction_set(random_word());

        // All opcode/funct3/funct7 combinations at fixed, nonzero register fields.
        for (int unsigned opcode = 0; opcode < 128; opcode++) begin
            for (int unsigned f3 = 0; f3 < 8; f3++) begin
                for (int unsigned f7 = 0; f7 < 128; f7++) begin
                    check_classification({7'(f7), 5'd3, 5'd2, 3'(f3), 5'd1, 7'(opcode)});
                end
            end
        end
        for (int unsigned bit_index = 0; bit_index < 32; bit_index++) begin
            check_classification(32'h0000_0073 ^ (32'd1 << bit_index));
            check_classification(32'h0010_0073 ^ (32'd1 << bit_index));
        end
        check_classification(32'h0000_100f); // FENCE.I is a separate extension.
        check_classification(32'h0220_81b3); // MUL is not RV32I.
        check_classification(32'hc000_20f3); // CSR read is not implemented.
        check_classification(32'h0000_0000); // Not a 32-bit RV32I instruction.
        $display("PASS: decoder 40 instructions/full controls, 131072 field combinations and reserved encodings (%0d checks; seed dec02026)", checks);
        $finish;
    end

    initial begin
        #500_000;
        $fatal(1, "TIMEOUT: decoder test");
    end
endmodule
