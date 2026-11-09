`timescale 1ns/1ps

// Self-checking bench for hazard.sv: directed cases named after the Phase 5
// plan, then every combination of the control inputs with registers from
// {x0, x5, x6}, against an independent reference model.
module hazard_tb;
    logic id_valid, id_uses_rs1, id_uses_rs2, ex_valid, ex_mem_read;
    logic ex_redirect, ex_stop, stop_pending;
    logic [4:0] id_rs1, id_rs2, ex_rd;
    logic load_use, stall, flush_id, bubble_ex, fetch_en, pc_hold;
    int unsigned checks = 0, stalls = 0, flushes = 0;

    hazard dut (.*);

    task automatic set(input bit idv, input logic [4:0] rs1, input logic [4:0] rs2,
                       input bit u1, input bit u2, input bit exv, input bit load,
                       input logic [4:0] rd, input bit redirect, input bit stop, input bit pending);
        id_valid = idv; id_rs1 = rs1; id_rs2 = rs2; id_uses_rs1 = u1; id_uses_rs2 = u2;
        ex_valid = exv; ex_mem_read = load; ex_rd = rd;
        ex_redirect = redirect; ex_stop = stop; stop_pending = pending;
        #1;
    endtask

    task automatic expect_out(input string name, input bit lu, input bit st, input bit fl,
                              input bit bub, input bit fe, input bit hold);
        if ({load_use, stall, flush_id, bubble_ex, fetch_en, pc_hold} !== {lu, st, fl, bub, fe, hold})
            $fatal(1, "%s: got load_use=%b stall=%b flush=%b bubble=%b fetch_en=%b pc_hold=%b",
                   name, load_use, stall, flush_id, bubble_ex, fetch_en, pc_hold);
        if (stall) stalls++;
        if (flush_id) flushes++;
        checks++;
    endtask

    initial begin
        logic [4:0] regs [3] = '{5'd0, 5'd5, 5'd6};
        // lw x5; add x7, x5, x5: stall one cycle, RAM enable low, bubble into EX.
        set(1, 5, 5, 1, 1, 1, 1, 5, 0, 0, 0); expect_out("load-use rs1/rs2", 1, 1, 0, 1, 0, 1);
        // lw x5; sw x5, 0(x6): store data is a use.
        set(1, 6, 5, 1, 1, 1, 1, 5, 0, 0, 0); expect_out("load then store data", 1, 1, 0, 1, 0, 1);
        // The consumer does not read that field (e.g. LUI's rs1 bits).
        set(1, 5, 0, 0, 0, 1, 1, 5, 0, 0, 0); expect_out("unused field", 0, 0, 0, 0, 1, 0);
        // lw x0 never stalls.
        set(1, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0); expect_out("load to x0", 0, 0, 0, 0, 1, 0);
        // An ALU producer never stalls (forwarding covers it).
        set(1, 5, 5, 1, 1, 1, 0, 5, 0, 0, 0); expect_out("ALU producer", 0, 0, 0, 0, 1, 0);
        // A bubble in EX or ID causes no stall.
        set(1, 5, 5, 1, 1, 0, 1, 5, 0, 0, 0); expect_out("bubble in EX", 0, 0, 0, 0, 1, 0);
        set(0, 5, 5, 1, 1, 1, 1, 5, 0, 0, 0); expect_out("bubble in ID", 0, 0, 0, 0, 1, 0);
        // Taken branch/JAL/JALR: flush ID and IF, keep fetching (the target).
        set(1, 5, 6, 1, 1, 1, 0, 1, 1, 0, 0); expect_out("redirect", 0, 0, 1, 1, 1, 0);
        // Halt or fault in EX: flush, stop fetching, hold the PC.
        set(1, 5, 6, 1, 1, 1, 0, 0, 0, 1, 0); expect_out("stop in EX", 0, 0, 1, 1, 0, 1);
        set(1, 5, 6, 1, 1, 0, 0, 0, 0, 0, 1); expect_out("stop pending", 0, 0, 1, 1, 0, 1);
        // A misaligned (faulting) load with a dependent: the flush wins.
        set(1, 5, 0, 1, 0, 1, 1, 5, 0, 1, 0); expect_out("faulting load", 1, 0, 1, 1, 0, 1);

        for (int flags = 0; flags < 256; flags++)
            for (int a = 0; a < 3; a++) for (int b = 0; b < 3; b++) for (int c = 0; c < 3; c++) begin
                bit lu, kill;
                bit [7:0] f = 8'(flags);
                set(f[0], regs[a], regs[b], f[1], f[2], f[3], f[4], regs[c], f[5], f[6], f[7]);
                lu = f[0] && f[3] && f[4] && regs[c] != 0 &&
                     ((f[1] && regs[a] == regs[c]) || (f[2] && regs[b] == regs[c]));
                kill = f[5] || f[6] || f[7];
                expect_out($sformatf("combination %0d/%0d%0d%0d", flags, a, b, c),
                           lu, lu && !kill, kill, kill || lu, !(lu && !kill) && !f[6] && !f[7],
                           (lu && !kill) || f[6] || f[7]);
            end
        if (stalls == 0 || flushes == 0) $fatal(1, "coverage hole");
        $display("PASS: hazard load-use stall, store-data use, x0, redirect/stop flush priority (%0d checks, %0d stalls, %0d flushes)",
                 checks, stalls, flushes);
        $finish;
    end
endmodule
