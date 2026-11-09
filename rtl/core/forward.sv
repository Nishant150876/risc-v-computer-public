`timescale 1ns/1ps

// Forwarding unit for the 5-stage pipeline. Purely combinational.
//
// For each EX source register (rs1, rs2; rs2 is also store data) choose the
// youngest older producer that is still in flight:
//   EX/MEM (distance 1) wins over MEM/WB (distance 2).
//   Distance 3 (producer in WB while the consumer is in ID) is covered by the
//   register file bypass, not here.
// A producer counts only if it is valid and writes a register (mem_rd_we /
// wb_rd_we are already false for x0, faults and no-write instructions); the
// rd != 0 check is repeated so a write to x0 can never be forwarded.
// A load in EX/MEM has no data yet; the hazard unit stalls so that case never
// reaches this unit.
module forward (
    input  logic                  mem_valid,
    input  logic                  mem_rd_we,
    input  logic [4:0]            mem_rd,
    input  logic                  wb_valid,
    input  logic                  wb_rd_we,
    input  logic [4:0]            wb_rd,
    input  logic [4:0]            ex_rs1,
    input  logic [4:0]            ex_rs2,
    output rv32i_pkg::fwd_sel_t   fwd_a,
    output rv32i_pkg::fwd_sel_t   fwd_b
);
    import rv32i_pkg::*;

    logic mem_live, wb_live;
    assign mem_live = mem_valid && mem_rd_we && mem_rd != 5'd0;
    assign wb_live  = wb_valid  && wb_rd_we  && wb_rd  != 5'd0;

    always_comb begin
        if (mem_live && mem_rd == ex_rs1)     fwd_a = FWD_MEM;
        else if (wb_live && wb_rd == ex_rs1)  fwd_a = FWD_WB;
        else                                  fwd_a = FWD_NONE;

        if (mem_live && mem_rd == ex_rs2)     fwd_b = FWD_MEM;
        else if (wb_live && wb_rd == ex_rs2)  fwd_b = FWD_WB;
        else                                  fwd_b = FWD_NONE;
    end
endmodule
