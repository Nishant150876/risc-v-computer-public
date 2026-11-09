`timescale 1ns/1ps

module alu_tb;
    import rv32i_pkg::*;

    logic [31:0] a = '0;
    logic [31:0] b = '0;
    alu_op_t op = ALU_ADD;
    logic [31:0] result;
    int unsigned checks = 0;
    logic [31:0] rng = 32'h13a1_2026;
    // 32'hffff_ffe0 has a zero shift count but every ignored upper bit set.
    logic [31:0] edges [0:12] = '{
        32'd0, 32'd1, 32'hffff_ffff, 32'h7fff_ffff,
        32'h8000_0000, 32'h8000_0001, 32'h5555_5555, 32'haaaa_aaaa,
        32'hdead_beef, 32'd31, 32'd32, 32'd63, 32'hffff_ffe0
    };

    alu dut (.a(a), .b(b), .op(op), .result(result));

    function automatic logic [31:0] random_word();
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        return rng;
    endfunction

    // Independent model: a bit-by-bit ripple-carry adder instead of the
    // + and < operators the ALU uses. SUB is a + ~b + 1. The comparisons come
    // from that subtraction: unsigned less-than is "no carry out", and signed
    // less-than is the sign bit XOR the signed-overflow bit.
    function automatic logic [32:0] ripple_add(
        input logic [31:0] left, right,
        input logic carry_in
    );
        logic [32:0] sum;
        logic carry;
        carry = carry_in;
        for (int unsigned bit_index = 0; bit_index < 32; bit_index++) begin
            sum[bit_index] = left[bit_index] ^ right[bit_index] ^ carry;
            carry = (left[bit_index] & right[bit_index])
                  | (carry & (left[bit_index] ^ right[bit_index]));
        end
        sum[32] = carry;
        return sum;
    endfunction

    function automatic logic [31:0] reference_result(
        input logic [31:0] left, right,
        input alu_op_t operation
    );
        logic [31:0] expected;
        logic [31:0] sum;
        logic [32:0] difference;
        int unsigned amount;
        logic overflow, signed_less, unsigned_less;
        expected = '0;
        amount = int'(right & 32'h1f);
        sum = 32'(ripple_add(left, right, 1'b0));  // carry out unused
        difference = ripple_add(left, ~right, 1'b1);
        unsigned_less = !difference[32];
        overflow = (left[31] != right[31]) && (difference[31] != left[31]);
        signed_less = difference[31] ^ overflow;
        case (operation)
            ALU_ADD: expected = sum[31:0];
            ALU_SUB: expected = difference[31:0];
            ALU_AND: expected = left & right;
            ALU_OR:  expected = left | right;
            ALU_XOR: expected = left ^ right;
            ALU_SLL: begin
                for (int unsigned bit_index = 0; bit_index < 32; bit_index++) begin
                    if (bit_index >= amount) expected[bit_index] = left[bit_index - amount];
                end
            end
            ALU_SRL, ALU_SRA: begin
                for (int unsigned bit_index = 0; bit_index < 32; bit_index++) begin
                    if (bit_index + amount < 32) expected[bit_index] = left[bit_index + amount];
                    else expected[bit_index] = (operation == ALU_SRA) && left[31];
                end
            end
            ALU_SLT:  expected = {31'd0, signed_less};
            ALU_SLTU: expected = {31'd0, unsigned_less};
            default:  expected = '0;
        endcase
        return expected;
    endfunction

    task automatic check_value(
        input alu_op_t operation,
        input logic [31:0] left, right, expected
    );
        op = operation;
        a = left;
        b = right;
        #1;
        assert (result === expected)
            else $fatal(1, "ALU %s(%0d) a=%h b=%h: expected %h, got %h",
                        operation.name(), operation, left, right, expected, result);
        checks++;
    endtask

    initial begin
        // Literal answers also check the model's signed and wrap conventions.
        check_value(ALU_ADD, 32'hffff_ffff, 32'd1, 32'd0);
        check_value(ALU_SUB, 32'd0, 32'd1, 32'hffff_ffff);
        check_value(ALU_SRA, 32'h8000_0000, 32'd31, 32'hffff_ffff);
        check_value(ALU_SRL, 32'h8000_0000, 32'd31, 32'd1);
        check_value(ALU_SLT, 32'h8000_0000, 32'h7fff_ffff, 32'd1);
        check_value(ALU_SLTU, 32'h8000_0000, 32'h7fff_ffff, 32'd0);
        check_value(ALU_SLL, 32'h1234_5678, 32'd32, 32'h1234_5678);
        check_value(ALU_ADD, 32'h7fff_ffff, 32'd1, 32'h8000_0000);  // signed overflow wraps
        check_value(ALU_SUB, 32'h8000_0000, 32'd1, 32'h7fff_ffff);  // signed underflow wraps
        check_value(ALU_SLT, 32'h7fff_ffff, 32'h8000_0000, 32'd0);  // overflowing subtraction
        check_value(ALU_SLT, 32'hffff_ffff, 32'd0, 32'd1);          // -1 < 0
        check_value(ALU_SLTU, 32'hffff_ffff, 32'd0, 32'd0);         // 0xffffffff > 0
        check_value(ALU_SRA, 32'h8000_0000, 32'hffff_ffe0, 32'h8000_0000); // count 0

        for (int unsigned code = 0; code < 10; code++) begin
            for (int unsigned i = 0; i < 13; i++) begin
                for (int unsigned j = 0; j < 13; j++) begin
                    check_value(alu_op_t'(code), edges[i], edges[j],
                                reference_result(edges[i], edges[j], alu_op_t'(code)));
                end
            end
            for (int unsigned trial = 0; trial < 1000; trial++) begin
                logic [31:0] left, right;
                left = random_word();
                right = random_word();
                check_value(alu_op_t'(code), left, right,
                            reference_result(left, right, alu_op_t'(code)));
            end
        end
        for (int unsigned code = 10; code < 16; code++) begin
            check_value(alu_op_t'(code), 32'hffff_ffff, 32'hffff_ffff, 32'd0);  // unused op codes
        end

        $display("PASS: ALU ten operations, directed edges and 1000 random pairs/op (%0d checks; seed 13a12026)", checks);
        $finish;
    end

    initial begin
        #100_000;
        $fatal(1, "TIMEOUT: ALU test");
    end
endmodule
