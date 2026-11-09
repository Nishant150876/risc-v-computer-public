`timescale 1ns/1ps

// x1-x31 have no reset (decision November 7, 2026): RISC-V does not require
// it, and a reset-free array maps onto LUTRAM instead of ~1,000 flip-flops.
// Startup code must set every register it relies on. x0 always reads 0.
module regfile #(
    parameter bit BYPASS = 1'b0
) (
    input  logic        clk,
    input  logic        we,
    input  logic [4:0]  waddr,
    input  logic [31:0] wdata,
    input  logic [4:0]  raddr1,
    input  logic [4:0]  raddr2,
    output logic [31:0] rdata1,
    output logic [31:0] rdata2
);
    logic [31:0] regs [0:31];

    // This is the only state writer. Later debug/BIST ownership must mux into
    // this write port rather than add an independent writer.
    always_ff @(posedge clk) begin
        if (we && waddr != 5'd0) begin
            regs[waddr] <= wdata;
        end
    end

    always_comb begin
        rdata1 = (raddr1 == 5'd0) ? 32'd0 : regs[raddr1];
        rdata2 = (raddr2 == 5'd0) ? 32'd0 : regs[raddr2];
        // Bypass is deliberately OFF in the single-cycle configuration.
        if (BYPASS && we && waddr != 5'd0) begin
            if (raddr1 == waddr) rdata1 = wdata;
            if (raddr2 == waddr) rdata2 = wdata;
        end
    end
endmodule
