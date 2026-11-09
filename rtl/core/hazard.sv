`timescale 1ns/1ps

// Hazard unit for the 5-stage pipeline. Purely combinational.
//
// Load-use: a valid load in EX whose rd (not x0) is a source the valid ID
//   instruction actually uses. ID and IF hold for one cycle (the block RAM
//   enable goes low so the IF/ID instruction stays put) and a bubble enters EX.
//   Store data counts as a use: lw x5 then sw x5 also stalls one cycle.
// Redirect: a taken branch, JAL or JALR resolves in EX (predict not-taken).
//   The two younger instructions, in ID and IF, are flushed.
// Stop: a valid halt (ECALL/EBREAK) or fault reaches EX. Younger instructions
//   are flushed and fetch stops; stop_pending keeps the front end empty while
//   the stopping instruction drains to WB.
// A flush always wins over a stall.
module hazard (
    input  logic       id_valid,
    input  logic [4:0] id_rs1,
    input  logic [4:0] id_rs2,
    input  logic       id_uses_rs1,
    input  logic       id_uses_rs2,
    input  logic       ex_valid,
    input  logic       ex_mem_read,
    input  logic [4:0] ex_rd,
    input  logic       ex_redirect,   // valid, non-faulting taken branch or jump
    input  logic       ex_stop,       // valid halt or fault in EX
    input  logic       stop_pending,  // a stopping instruction is in MEM or WB
    output logic       load_use,
    output logic       stall,         // hold PC and IF/ID; block RAM enable low
    output logic       flush_id,      // the IF/ID instruction becomes a bubble
    output logic       bubble_ex,     // ID/EX receives a bubble
    output logic       fetch_en,      // instruction port enable
    output logic       pc_hold        // keep the fetch PC (unless redirected)
);
    logic kill;

    always_comb begin
        load_use = ex_valid && ex_mem_read && ex_rd != 5'd0 && id_valid &&
                   ((id_uses_rs1 && id_rs1 == ex_rd) || (id_uses_rs2 && id_rs2 == ex_rd));
        kill      = ex_redirect || ex_stop || stop_pending;
        stall     = load_use && !kill;
        flush_id  = kill;
        bubble_ex = kill || load_use;
        fetch_en  = !stall && !ex_stop && !stop_pending;
        pc_hold   = stall || ex_stop || stop_pending;
    end
endmodule
