`timescale 1ns/1ps

// Phase 5 first pass: cpu_pipe with DATA_HAZARDS = 0 (no forwarding, no
// register file bypass, no load-use stall) next to the full pipeline.
//   Program A puts three NOPs between every producer and consumer, including
//   a store's data and a load's user. Both configurations must compute it.
//   Program B has no NOPs. The full pipeline must still be right; the first
//   pass must read the stale (preloaded) registers, proving that program A
//   passes because of the spacing and that the hazard logic is what fixes B.
// Programs are hand-encoded here so this bench needs no toolchain.
module pipe_first_pass_tb;
    import rv32i_pkg::*;

    logic clk = 0, rst = 1;
    always #20 clk <= ~clk;

    localparam logic [31:0] NOP = 32'h0000_0013, ECALL = 32'h0000_0073;
    function automatic logic [31:0] addi(input logic [4:0] rd, input logic [4:0] rs1, input logic [11:0] imm);
        return {imm, rs1, 3'b000, rd, 7'b0010011};
    endfunction
    function automatic logic [31:0] add(input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2);
        return {7'b0, rs2, rs1, 3'b000, rd, 7'b0110011};
    endfunction
    function automatic logic [31:0] lw(input logic [4:0] rd, input logic [4:0] rs1, input logic [11:0] imm);
        return {imm, rs1, 3'b010, rd, 7'b0000011};
    endfunction
    function automatic logic [31:0] sw(input logic [4:0] rs2, input logic [4:0] rs1, input logic [11:0] imm);
        return {imm[11:5], rs2, rs1, 3'b010, imm[4:0], 7'b0100011};
    endfunction

    // Two CPUs, each with its own RAM wired straight to the data port.
    logic [1:0] imem_en, dmem_re, halted;
    logic [31:0] imem_addr [2], imem_rdata [2], dmem_addr [2], dmem_wdata [2], dmem_rdata [2];
    logic [3:0] dmem_wstrb [2];
    retire_t retire [2];
    stop_cause_t cause [2];

    cpu_pipe #(.DATA_HAZARDS(1'b0)) u_first (
        .clk(clk), .rst(rst), .imem_en(imem_en[0]), .imem_addr(imem_addr[0]), .imem_rdata(imem_rdata[0]),
        .dmem_re(dmem_re[0]), .dmem_wstrb(dmem_wstrb[0]), .dmem_addr(dmem_addr[0]),
        .dmem_wdata(dmem_wdata[0]), .dmem_rdata(dmem_rdata[0]), .retire(retire[0]),
        .halted(halted[0]), .stop_cause(cause[0])
    );
    cpu_pipe #(.DATA_HAZARDS(1'b1)) u_full (
        .clk(clk), .rst(rst), .imem_en(imem_en[1]), .imem_addr(imem_addr[1]), .imem_rdata(imem_rdata[1]),
        .dmem_re(dmem_re[1]), .dmem_wstrb(dmem_wstrb[1]), .dmem_addr(dmem_addr[1]),
        .dmem_wdata(dmem_wdata[1]), .dmem_rdata(dmem_rdata[1]), .retire(retire[1]),
        .halted(halted[1]), .stop_cause(cause[1])
    );
    ram #(.WORDS(1024), .PORTB_NEGEDGE(1'b0)) u_ram_first (
        .clk(clk), .a_en(imem_en[0]), .a_addr(imem_addr[0]), .a_rdata(imem_rdata[0]),
        .b_en(dmem_re[0] || dmem_wstrb[0] != 0), .b_wstrb(dmem_wstrb[0]), .b_addr(dmem_addr[0]),
        .b_wdata(dmem_wdata[0]), .b_rdata(dmem_rdata[0])
    );
    ram #(.WORDS(1024), .PORTB_NEGEDGE(1'b0)) u_ram_full (
        .clk(clk), .a_en(imem_en[1]), .a_addr(imem_addr[1]), .a_rdata(imem_rdata[1]),
        .b_en(dmem_re[1] || dmem_wstrb[1] != 0), .b_wstrb(dmem_wstrb[1]), .b_addr(dmem_addr[1]),
        .b_wdata(dmem_wdata[1]), .b_rdata(dmem_rdata[1])
    );

    logic [31:0] program_words[$];
    int unsigned checks = 0;

    task automatic emit(input logic [31:0] word, input int nops = 0);
        program_words.push_back(word);
        repeat (nops) program_words.push_back(NOP);
    endtask

    task automatic run(input string name);
        rst = 1;
        for (int i = 0; i < 1024; i++) begin
            u_ram_first.mem[i] = ECALL;
            u_ram_full.mem[i] = ECALL;
        end
        foreach (program_words[i]) begin
            u_ram_first.mem[i] = program_words[i];
            u_ram_full.mem[i] = program_words[i];
        end
        // Stale values the first pass would read without forwarding.
        for (int r = 1; r < 32; r++) begin
            u_first.u_regfile.regs[r] = 32'd100 * r;
            u_full.u_regfile.regs[r] = 32'd100 * r;
        end
        repeat (2) @(posedge clk);
        #1 rst = 0;
        for (int cycle = 0; halted != 2'b11; cycle++) begin
            if (cycle > 500) $fatal(1, "%s: timeout", name);
            @(posedge clk); #1;
        end
        if (cause[0] != STOP_ECALL || cause[1] != STOP_ECALL) $fatal(1, "%s: did not stop with ECALL", name);
        program_words.delete();
    endtask

    function automatic logic [31:0] reg_of(input bit full, input logic [4:0] r);
        return full ? u_full.u_regfile.regs[r] : u_first.u_regfile.regs[r];
    endfunction

    task automatic expect_reg(input string name, input bit full, input logic [4:0] r, input logic [31:0] value);
        if (reg_of(full, r) !== value)
            $fatal(1, "%s (%s): x%0d = %h, expected %h", name, full ? "full pipeline" : "first pass",
                   r, reg_of(full, r), value);
        checks++;
    endtask

    initial begin
        // Program A: three NOPs between every dependent pair.
        emit(addi(1, 0, 5), 3);
        emit(addi(2, 1, 7), 3);          // x2 = 12
        emit(add(3, 2, 1), 3);           // x3 = 17
        emit(sw(3, 0, 256));             // store data x3, three NOPs after its producer
        emit(lw(4, 0, 256), 3);          // x4 = 17
        emit(add(5, 4, 4), 3);           // x5 = 34
        emit(ECALL);
        run("program A");
        for (int full = 0; full < 2; full++) begin
            expect_reg("program A", full[0], 2, 12);
            expect_reg("program A", full[0], 3, 17);
            expect_reg("program A", full[0], 4, 17);
            expect_reg("program A", full[0], 5, 34);
        end

        // Program B: back-to-back dependencies and a load-use.
        emit(addi(1, 0, 5));
        emit(addi(2, 1, 7));             // full: 12; first pass: 100 + 7
        emit(add(3, 2, 1));              // full: 17; first pass: 200 + 100
        emit(sw(3, 0, 256));
        emit(lw(4, 0, 256));
        emit(add(5, 4, 4));              // full: 34; first pass: 400 + 400
        emit(ECALL);
        run("program B");
        expect_reg("program B", 1, 2, 12);
        expect_reg("program B", 1, 3, 17);
        expect_reg("program B", 1, 5, 34);
        expect_reg("program B", 0, 2, 107);
        expect_reg("program B", 0, 3, 300);
        expect_reg("program B", 0, 5, 800);
        $display("PASS: first-pass pipeline (no hazard logic) runs 3-NOP code; full pipeline also runs it without NOPs (%0d register checks)", checks);
        $finish;
    end

    logic unused;
    assign unused = ^{retire[0], retire[1]};
endmodule
