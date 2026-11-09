`timescale 1ns/1ps

// Self-checking bench for forward.sv. Exhaustive over the cases that matter:
// every valid/write-enable combination of both producers, with rd and rs
// drawn from {x0, x1, x2, x31} (all equal/unequal patterns, including x0),
// then random full-range registers. The reference picks the youngest valid,
// writing, nonzero producer.
module forward_tb;
    import rv32i_pkg::*;

    logic mem_valid, mem_rd_we, wb_valid, wb_rd_we;
    logic [4:0] mem_rd, wb_rd, ex_rs1, ex_rs2;
    fwd_sel_t fwd_a, fwd_b;
    int unsigned checks = 0, from_mem = 0, from_wb = 0, x0_blocked = 0;
    logic [31:0] rng = 32'h0f0f_2026;

    forward dut (.*);

    function automatic fwd_sel_t model(input logic [4:0] rs);
        bit mem_hit = mem_valid && mem_rd_we && mem_rd == rs && rs != 0;
        bit wb_hit = wb_valid && wb_rd_we && wb_rd == rs && rs != 0;
        if (mem_hit) return FWD_MEM;
        if (wb_hit) return FWD_WB;
        return FWD_NONE;
    endfunction

    task automatic check();
        #1;
        if (fwd_a !== model(ex_rs1) || fwd_b !== model(ex_rs2))
            $fatal(1, "mem v%0b we%0b rd%0d, wb v%0b we%0b rd%0d, rs1 %0d rs2 %0d: got a=%0d b=%0d",
                   mem_valid, mem_rd_we, mem_rd, wb_valid, wb_rd_we, wb_rd, ex_rs1, ex_rs2, fwd_a, fwd_b);
        if (fwd_a == FWD_MEM) from_mem++;
        if (fwd_a == FWD_WB) from_wb++;
        if (ex_rs1 == 0 && ((mem_valid && mem_rd_we && mem_rd == 0) || (wb_valid && wb_rd_we && wb_rd == 0)))
            x0_blocked++;
        checks++;
    endtask

    function automatic logic [31:0] random_word();
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        return rng;
    endfunction

    initial begin
        logic [4:0] regs [4] = '{5'd0, 5'd1, 5'd2, 5'd31};
        for (int flags = 0; flags < 16; flags++)
            for (int a = 0; a < 4; a++) for (int b = 0; b < 4; b++)
                for (int c = 0; c < 4; c++) for (int d = 0; d < 4; d++) begin
                    {mem_valid, mem_rd_we, wb_valid, wb_rd_we} = 4'(flags);
                    mem_rd = regs[a]; wb_rd = regs[b]; ex_rs1 = regs[c]; ex_rs2 = regs[d];
                    check();
                end
        repeat (20000) begin
            logic [31:0] r = random_word();
            {mem_valid, mem_rd_we, wb_valid, wb_rd_we} = r[3:0];
            mem_rd = r[8:4]; wb_rd = r[13:9]; ex_rs1 = r[18:14]; ex_rs2 = r[23:19];
            if (r[24]) wb_rd = mem_rd;      // force same-register producers often
            if (r[25]) ex_rs1 = mem_rd;
            if (r[26]) ex_rs2 = wb_rd;
            if (&r[31:27]) {mem_valid, mem_rd_we} = 2'b11;  // bias towards live MEM producers
            check();
        end
        if (from_mem == 0 || from_wb == 0 || x0_blocked == 0) $fatal(1, "coverage hole");
        $display("PASS: forward priority, both sources and x0 never forwarded (%0d checks: %0d MEM, %0d WB, %0d x0 writes blocked)",
                 checks, from_mem, from_wb, x0_blocked);
        $finish;
    end
endmodule
