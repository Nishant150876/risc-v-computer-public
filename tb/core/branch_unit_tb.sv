`timescale 1ns/1ps

module branch_unit_tb;
    import rv32i_pkg::*;

    logic [31:0] a = '0;
    logic [31:0] b = '0;
    branch_t branch = BR_NONE;
    logic taken;
    logic [31:0] rng = 32'hb2a1_2026;
    int unsigned checks = 0;
    logic [31:0] edges [0:7] = '{
        32'd0, 32'd1, 32'hffff_ffff, 32'h7fff_ffff,
        32'h8000_0000, 32'h8000_0001, 32'h5555_5555, 32'haaaa_aaaa
    };

    branch_unit dut (.a(a), .b(b), .branch(branch), .taken(taken));

    function automatic logic [31:0] random_word();
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        return rng;
    endfunction

    // Independent model: compute a - b as a + ~b + 1 one bit at a time instead
    // of using the < operator the DUT uses. Unsigned less-than is "no carry
    // out"; signed less-than is the result's sign XOR signed overflow.
    function automatic logic reference_taken(
        input branch_t condition,
        input logic [31:0] left, right
    );
        logic [31:0] difference;
        logic carry, overflow, signed_less, unsigned_less;
        carry = 1'b1;
        for (int unsigned bit_index = 0; bit_index < 32; bit_index++) begin
            difference[bit_index] = left[bit_index] ^ ~right[bit_index] ^ carry;
            carry = (left[bit_index] & ~right[bit_index])
                  | (carry & (left[bit_index] ^ ~right[bit_index]));
        end
        unsigned_less = !carry;
        overflow = (left[31] != right[31]) && (difference[31] != left[31]);
        signed_less = difference[31] ^ overflow;
        case (condition)
            BR_EQ:  return difference == 32'd0;
            BR_NE:  return difference != 32'd0;
            BR_LT:  return signed_less;
            BR_GE:  return !signed_less;
            BR_LTU: return unsigned_less;
            BR_GEU: return !unsigned_less;
            default: return 1'b0;
        endcase
    endfunction

    task automatic check_value(
        input branch_t condition,
        input logic [31:0] left, right,
        input logic expected
    );
        branch = condition;
        a = left;
        b = right;
        #1;
        assert (taken === expected)
            else $fatal(1, "branch %s(%0d) a=%h b=%h: expected %b, got %b",
                        condition.name(), condition, left, right, expected, taken);
        checks++;
    endtask

    initial begin
        check_value(BR_LT, 32'hffff_ffff, 32'd1, 1'b1);
        check_value(BR_LTU, 32'hffff_ffff, 32'd1, 1'b0);
        check_value(BR_GE, 32'h8000_0000, 32'h7fff_ffff, 1'b0);
        check_value(BR_GEU, 32'h8000_0000, 32'h7fff_ffff, 1'b1);
        check_value(BR_LT, 32'h7fff_ffff, 32'h8000_0000, 1'b0);   // a - b overflows
        check_value(BR_LTU, 32'h7fff_ffff, 32'h8000_0000, 1'b1);
        check_value(BR_GE, 32'h8000_0000, 32'h8000_0000, 1'b1);   // equal is >=
        check_value(BR_GEU, 32'd0, 32'd0, 1'b1);
        check_value(BR_EQ, 32'h8000_0000, 32'h0000_0000, 1'b0);  // only bit 31 differs
        check_value(BR_NE, 32'h0000_0001, 32'h0000_0000, 1'b1);  // only bit 0 differs
        for (int unsigned code = 0; code < 8; code++) begin
            for (int unsigned i = 0; i < 8; i++) begin
                for (int unsigned j = 0; j < 8; j++) begin
                    check_value(branch_t'(code), edges[i], edges[j],
                                reference_taken(branch_t'(code), edges[i], edges[j]));
                end
            end
            for (int unsigned trial = 0; trial < 1000; trial++) begin
                logic [31:0] left, right;
                left = random_word();
                right = (trial % 7 == 0) ? left : random_word();
                check_value(branch_t'(code), left, right,
                            reference_taken(branch_t'(code), left, right));
            end
        end
        $display("PASS: all branch conditions, signed/unsigned edges, equality and random pairs (%0d checks; seed b2a12026)", checks);
        $finish;
    end

    initial begin
        #100_000;
        $fatal(1, "TIMEOUT: branch test");
    end
endmodule
