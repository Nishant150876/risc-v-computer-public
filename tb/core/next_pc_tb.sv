`timescale 1ns/1ps

// next_pc: sequential, branch, JAL and JALR targets, bit-0 clearing,
// misaligned-target detection, reset and hold. The reference builds targets
// with a ripple-carry adder, independent of the RTL's '+'.
module next_pc_tb;
    import rv32i_pkg::*;

    logic [31:0] pc, rs1, imm;
    jump_t       jump;
    logic        branch_taken, rst, hold;
    logic [31:0] pc_plus4, target, next;
    logic        redirect, misaligned;
    logic [31:0] rng = 32'h0bad_2026;
    int unsigned checks = 0;

    next_pc dut (
        .pc(pc), .rs1(rs1), .imm(imm), .jump(jump), .branch_taken(branch_taken),
        .rst(rst), .hold(hold), .pc_plus4(pc_plus4), .target(target),
        .redirect(redirect), .misaligned(misaligned), .next(next)
    );

    function automatic logic [31:0] random_word();
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        return rng;
    endfunction

    function automatic logic [31:0] ripple_add(input logic [31:0] a, input logic [31:0] b);
        logic [31:0] sum;
        logic carry = 1'b0;
        for (int i = 0; i < 32; i++) begin
            sum[i] = a[i] ^ b[i] ^ carry;
            carry  = (a[i] & b[i]) | (carry & (a[i] ^ b[i]));
        end
        return sum;
    endfunction

    task automatic check(
        input logic [31:0] t_pc, t_rs1, t_imm, input jump_t t_jump,
        input logic t_taken, t_rst, t_hold
    );
        logic [31:0] e_plus4, e_target, e_next;
        logic e_redirect, e_mis;
        pc = t_pc; rs1 = t_rs1; imm = t_imm; jump = t_jump;
        branch_taken = t_taken; rst = t_rst; hold = t_hold;
        #1;
        e_plus4 = ripple_add(t_pc, 32'd4);
        if (t_jump == JUMP_JALR) begin
            e_target = ripple_add(t_rs1, t_imm);
            e_target[0] = 1'b0;
        end else begin
            e_target = ripple_add(t_pc, t_imm);
        end
        e_redirect = (t_jump != JUMP_NONE) || t_taken;
        e_mis = e_redirect && (e_target % 4 != 0);
        if (t_rst)       e_next = 32'h0000_0000;
        else if (t_hold) e_next = t_pc;
        else             e_next = e_redirect ? e_target : e_plus4;
        assert ({pc_plus4, target, redirect, misaligned, next} ===
                {e_plus4, e_target, e_redirect, e_mis, e_next})
            else $fatal(1, "pc=%h rs1=%h imm=%h jump=%0d taken=%b rst=%b hold=%b: expected +4=%h tgt=%h redir=%b mis=%b next=%h, got %h %h %b %b %h",
                        t_pc, t_rs1, t_imm, t_jump, t_taken, t_rst, t_hold,
                        e_plus4, e_target, e_redirect, e_mis, e_next,
                        pc_plus4, target, redirect, misaligned, next);
        checks++;
    endtask

    initial begin
        // Sequential flow, including the 32-bit wrap.
        check(32'h0000_0000, 0, 0, JUMP_NONE, 0, 0, 0);
        check(32'h0000_fffc, 0, 0, JUMP_NONE, 0, 0, 0);
        check(32'hffff_fffc, 0, 0, JUMP_NONE, 0, 0, 0);
        // Branch not taken ignores the immediate; taken uses pc + imm.
        check(32'h0000_0100, 0, 32'hffff_fff0, JUMP_NONE, 0, 0, 0);
        check(32'h0000_0100, 0, 32'hffff_fff0, JUMP_NONE, 1, 0, 0);
        check(32'h0000_0100, 0, 32'h0000_0ffe, JUMP_NONE, 1, 0, 0); // max B offset
        check(32'h0000_1000, 0, 32'hffff_f000, JUMP_NONE, 1, 0, 0); // min B offset
        check(32'h0000_0100, 0, 32'h0000_0002, JUMP_NONE, 1, 0, 0); // misaligned
        // Full module inputs can be odd, even though decoded B/J offsets are even.
        check(32'h0000_0100, 0, 32'h0000_0001, JUMP_NONE, 1, 0, 0);
        check(32'h0000_0100, 0, 32'h0000_0001, JUMP_NONE, 0, 0, 0);
        check(32'h0000_0100, 0, 32'h0000_0001, JUMP_JAL, 0, 0, 0);
        // JAL ignores branch_taken and rs1.
        check(32'h0000_0200, 32'hdead_beef, 32'h000f_fffe, JUMP_JAL, 0, 0, 0);
        check(32'h0000_0200, 32'hdead_beef, 32'hfff0_0000, JUMP_JAL, 0, 0, 0);
        check(32'h0000_0200, 0, 32'h0000_0006, JUMP_JAL, 0, 0, 0);          // misaligned
        // JALR clears bit 0 only; bit 1 still faults.
        check(32'h0000_0300, 32'h0000_1001, 32'h0000_0000, JUMP_JALR, 0, 0, 0);
        check(32'h0000_0300, 32'h0000_1000, 32'h0000_0001, JUMP_JALR, 0, 0, 0);
        check(32'h0000_0300, 32'h0000_1000, 32'h0000_0003, JUMP_JALR, 0, 0, 0);
        check(32'h0000_0300, 32'h0000_1000, 32'hffff_ffff, JUMP_JALR, 0, 0, 0);
        check(32'h0000_0300, 32'hffff_ffff, 32'h0000_0001, JUMP_JALR, 0, 0, 0);
        // Reset beats hold, and both beat a redirect.
        check(32'h0000_0400, 0, 32'h40, JUMP_JAL, 1, 1, 1);
        check(32'h0000_0400, 0, 32'h40, JUMP_JAL, 1, 1, 0);
        check(32'h0000_0400, 0, 32'h40, JUMP_JAL, 1, 0, 1);
        check(32'h0000_0400, 0, 32'h40, JUMP_NONE, 0, 0, 1);

        for (int unsigned trial = 0; trial < 20000; trial++) begin
            logic [12:0] controls = 13'(random_word());
            jump_t j;
            case (controls[1:0])
                2'd0, 2'd3: j = JUMP_NONE;
                2'd1: j = JUMP_JAL;
                default: j = JUMP_JALR;
            endcase
            check({random_word()}, random_word(), random_word(), j,
                  controls[2], controls[7:3] == 0, controls[12:8] == 0);
        end

        $display("PASS: next_pc sequential, branch, JAL, JALR, misaligned targets, reset and hold (%0d checks; seed 0bad2026)", checks);
        $finish;
    end
endmodule
