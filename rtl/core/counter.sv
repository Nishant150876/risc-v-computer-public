`timescale 1ns/1ps

// Phase 0 simulation smoke test: a four-bit, synchronous-reset counter.
module counter (
    input  logic       clk,
    input  logic       rst,
    output logic [3:0] count
);
    always_ff @(posedge clk) begin
        if (rst) begin
            count <= 4'd0;
        end else begin
            count <= count + 4'd1;
        end
    end
endmodule
