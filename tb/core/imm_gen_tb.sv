`timescale 1ns/1ps

module imm_gen_tb;
    import rv32i_pkg::*;

    logic [31:0] instr = '0;
    imm_sel_t imm_sel = IMM_NONE;
    logic [31:0] imm;
    logic [31:0] rng = 32'h1a1d_2026;
    int unsigned checks = 0;

    imm_gen dut (.instr(instr), .imm_sel(imm_sel), .imm(imm));

    function automatic logic [31:0] random_word();
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        return rng;
    endfunction

    task automatic check_value(
        input imm_sel_t format,
        input logic [31:0] instruction, expected
    );
        instr = instruction;
        imm_sel = format;
        #1;
        assert (imm === expected)
            else $fatal(1, "immediate %s(%0d) instr=%h: expected %h, got %h",
                        format.name(), format, instruction, expected, imm);
        checks++;
    endtask

    // Build an instruction from a known signed value. The expected value is
    // the original number, not a second copy of the DUT's extraction logic.
    task automatic check_encoded(input imm_sel_t format, input logic [31:0] value);
        logic [31:0] instruction;
        case (format)
            IMM_I: instruction = {value[11:0], 5'd9, 3'b000, 5'd5, 7'h13};
            IMM_S: instruction = {value[11:5], 5'd5, 5'd9, 3'b010, value[4:0], 7'h23};
            IMM_B: instruction = {value[12], value[10:5], 5'd5, 5'd9, 3'b000,
                                  value[4:1], value[11], 7'h63};
            IMM_U: instruction = {value[31:12], 5'd5, 7'h37};
            IMM_J: instruction = {value[20], value[10:1], value[11], value[19:12], 5'd5, 7'h6f};
            default: instruction = 32'd0;
        endcase
        check_value(format, instruction, value);
        // Vary the unused opcode independently; format is an explicit input.
        instruction[6:0] = ~instruction[6:0];
        check_value(format, instruction, value);
    endtask

    initial begin
        check_value(IMM_I, 32'hfff0_0293, 32'hffff_ffff);
        check_value(IMM_I, 32'h7ff0_0093, 32'h0000_07ff);
        check_value(IMM_I, 32'h8000_0093, 32'hffff_f800);
        check_value(IMM_I, 32'h0000_0093, 32'h0000_0000);
        check_value(IMM_S, 32'hfe31_2fa3, 32'hffff_ffff);
        check_value(IMM_S, 32'h7e31_2fa3, 32'h0000_07ff);
        check_value(IMM_S, 32'h8031_2023, 32'hffff_f800);
        check_value(IMM_S, 32'h0031_2023, 32'h0000_0000);
        check_value(IMM_B, 32'hfe20_8ee3, 32'hffff_fffc);
        check_value(IMM_B, 32'h7e20_8fe3, 32'h0000_0ffe);
        check_value(IMM_B, 32'h8020_8063, 32'hffff_f000);
        check_value(IMM_B, 32'h0020_8063, 32'h0000_0000);
        check_value(IMM_J, 32'hffdf_f0ef, 32'hffff_fffc);
        check_value(IMM_J, 32'h7fff_f0ef, 32'h000f_fffe);
        check_value(IMM_J, 32'h8000_00ef, 32'hfff0_0000);
        check_value(IMM_J, 32'h0000_00ef, 32'h0000_0000);
        check_value(IMM_U, 32'habcd_e2b7, 32'habcd_e000);
        check_value(IMM_U, 32'h8000_02b7, 32'h8000_0000);
        check_value(IMM_U, 32'hffff_f2b7, 32'hffff_f000);
        check_value(IMM_U, 32'h0000_02b7, 32'h0000_0000);

        // One-hot values expose every immediate bit's wiring, including sign.
        for (int unsigned code = 1; code <= 5; code++) begin
            for (int unsigned bit_index = 0; bit_index < 32; bit_index++) begin
                logic [31:0] value;
                value = 32'd1 << bit_index;
                case (imm_sel_t'(code))
                    IMM_I, IMM_S: value = 32'($signed(value[11:0]));
                    IMM_B: value = 32'($signed({value[12:1], 1'b0}));
                    IMM_U: value &= 32'hffff_f000;
                    IMM_J: value = 32'($signed({value[20:1], 1'b0}));
                    default: value = '0;
                endcase
                check_encoded(imm_sel_t'(code), value);
            end
            for (int unsigned trial = 0; trial < 1000; trial++) begin
                logic [31:0] value;
                int signed number;
                value = random_word();
                case (imm_sel_t'(code))
                    IMM_I, IMM_S: begin
                        number = int'(value & 32'hfff);
                        if (number >= 2048) number -= 4096;
                        value = 32'(number);
                    end
                    IMM_B: begin
                        number = int'(value & 32'h1ffe);
                        if (number >= 4096) number -= 8192;
                        value = 32'(number);
                    end
                    IMM_U: value &= 32'hffff_f000;
                    IMM_J: begin
                        number = int'(value & 32'h1f_fffe);
                        if (number >= 1048576) number -= 2097152;
                        value = 32'(number);
                    end
                    default: value = '0;
                endcase
                check_encoded(imm_sel_t'(code), value);
            end
        end
        check_value(IMM_NONE, 32'hffff_ffff, 32'd0);
        check_value(imm_sel_t'(6), 32'hffff_ffff, 32'd0);
        check_value(imm_sel_t'(7), 32'hffff_ffff, 32'd0);
        $display("PASS: I/S/B/U/J literals, one-hot wiring, signed limits and random round trips (%0d checks; seed 1a1d2026)", checks);
        $finish;
    end

    initial begin
        #100_000;
        $fatal(1, "TIMEOUT: immediate test");
    end
endmodule
