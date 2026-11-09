`timescale 1ns/1ps

module branch_unit (
    input  logic [31:0]      a,
    input  logic [31:0]      b,
    input  rv32i_pkg::branch_t branch,
    output logic            taken
);
    import rv32i_pkg::*;

    // Target generation and alignment checking belong to Phase 2's next PC.
    always_comb begin
        case (branch)
            BR_EQ:   taken = a == b;
            BR_NE:   taken = a != b;
            BR_LT:   taken = $signed(a) < $signed(b);
            BR_GE:   taken = $signed(a) >= $signed(b);
            BR_LTU:  taken = a < b;
            BR_GEU:  taken = a >= b;
            default: taken = 1'b0;
        endcase
    end
endmodule
