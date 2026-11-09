`timescale 1ns/1ps

// Phase 3 baseline counters. Count active CPU cycles and actual retirement,
// including ECALL/EBREAK once. Reset for a new CPU run, wrap modulo 2**WIDTH.
module perf_counters #(
    parameter int WIDTH = 32
) (
    input logic clk,
    input logic rst,
    input logic running,
    input logic retire_valid,
    output logic [WIDTH-1:0] cycles,
    output logic [WIDTH-1:0] instret
);
    always_ff @(posedge clk) begin
        if (rst) begin
            cycles <= '0;
            instret <= '0;
        end else if (running) begin
            cycles <= cycles + 1'b1;
            if (retire_valid) instret <= instret + 1'b1;
        end
    end
endmodule
