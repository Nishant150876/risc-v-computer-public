`timescale 1ns/1ps

// Single-cycle RV32I CPU. Every instruction completes in one clock.
//
// Edge schedule (proven by tb/mem/ram_tb.sv, see docs/phases/PHASE2_SINGLE_CYCLE.md):
//   rising edge   PC <= next PC; instruction port latches mem[next PC], so
//                 the new instruction is ready at the start of its cycle;
//                 the register file writes the previous instruction's result.
//   first half    decode, register read, ALU -> data address and store data.
//   falling edge  data port reads (loads) or writes (stores) that address.
//   second half   load lane select/extend; next PC and write-back settle.
//
// Stop contract: ECALL/EBREAK retire, then the CPU stops with PC = pc + 4.
// A fault (illegal, misaligned target, misaligned load/store) does not
// retire, writes nothing, and stops with PC still at the faulting instruction.
// Only reset restarts a stopped CPU.
module cpu_single #(
    parameter bit DEBUG_ENABLE=0
) (
    input  logic                      clk,
    input  logic                      rst,
    // Instruction port: synchronous read on the rising edge.
    output logic [31:0]               imem_addr,
    input  logic [31:0]               imem_rdata,
    // Data port: synchronous read/write on the falling edge.
    output logic                      dmem_re,
    output logic [3:0]                dmem_wstrb,
    output logic [31:0]               dmem_addr,
    output logic [31:0]               dmem_wdata,
    input  logic [31:0]               dmem_rdata,
    // Architectural observation.
    output rv32i_pkg::retire_t        retire,
    output logic                      halted,
    output rv32i_pkg::stop_cause_t    stop_cause,
    input rv32i_pkg::cpu_debug_control_t debug_control,
    output rv32i_pkg::cpu_debug_status_t debug_status
);
    import rv32i_pkg::*;

    logic [31:0] pc, pc_next, pc_plus4;
    logic [31:0] instr;
    control_t    ctrl;
    logic [31:0] imm, rs1_data, rs2_data;
    logic [31:0] op_a, op_b, alu_result;
    logic        branch_taken;
    logic [31:0] target;
    logic        redirect, target_misaligned;
    logic [31:0] load_data;
    logic        lsu_re, lsu_misaligned;
    logic [3:0]  lsu_wstrb;
    logic [31:0] lsu_wdata;
    logic [31:0] wb_data;
    logic        active, fault, commit, rd_we;
    stop_cause_t fault_cause;
    logic        halted_q;
    stop_cause_t stop_cause_q;
    logic debug_hold,debug_break,debug_step;
    logic [31:0] debug_last_pc;
    logic debug_last_valid,debug_writer;
    logic [4:0] rf_waddr,rf_raddr1;
    logic [31:0] rf_wdata;
    logic rf_we;
    logic [31:0] actual_alu_a,actual_alu_b;
    alu_op_t actual_alu_op;
    function automatic logic breakpoint_at(input logic [31:0] address);
        return DEBUG_ENABLE &&
               ((debug_control.breakpoint_enable[0] && debug_control.breakpoint0==address) ||
                (debug_control.breakpoint_enable[1] && debug_control.breakpoint1==address));
    endfunction
    assign debug_writer=DEBUG_ENABLE && (debug_hold || halted_q) && !rst && debug_control.reg_we;
    assign rf_we=debug_writer ? debug_control.reg_addr!=0 : rd_we;
    assign rf_waddr=debug_writer ? debug_control.reg_addr : instr[11:7];
    assign rf_wdata=debug_writer ? debug_control.reg_wdata : wb_data;
    assign rf_raddr1=(DEBUG_ENABLE && (debug_hold || halted_q)) ? debug_control.reg_addr : instr[19:15];

    assign instr = imem_rdata;

    decoder u_decoder (.instr(instr), .ctrl(ctrl));
    imm_gen u_imm_gen (.instr(instr), .imm_sel(ctrl.imm_sel), .imm(imm));

    regfile #(.BYPASS(1'b0)) u_regfile (
        .clk(clk), .we(rf_we), .waddr(rf_waddr), .wdata(rf_wdata),
        .raddr1(rf_raddr1), .raddr2(instr[24:20]),
        .rdata1(rs1_data), .rdata2(rs2_data)
    );

    always_comb begin
        case (ctrl.op_a_sel)
            OPA_PC:   op_a = pc;
            OPA_ZERO: op_a = 32'd0;
            default:  op_a = rs1_data;
        endcase
        op_b = (ctrl.op_b_sel == OPB_IMM) ? imm : rs2_data;
    end

    assign actual_alu_a=DEBUG_ENABLE && (debug_hold || halted_q) && debug_control.alu_test ? debug_control.alu_a : op_a;
    assign actual_alu_b=DEBUG_ENABLE && (debug_hold || halted_q) && debug_control.alu_test ? debug_control.alu_b : op_b;
    assign actual_alu_op=DEBUG_ENABLE && (debug_hold || halted_q) && debug_control.alu_test ? debug_control.alu_op : ctrl.alu_op;
    alu u_alu (.a(actual_alu_a), .b(actual_alu_b), .op(actual_alu_op), .result(alu_result));

    branch_unit u_branch (
        .a(rs1_data), .b(rs2_data), .branch(ctrl.branch), .taken(branch_taken)
    );

    lsu u_lsu (
        .mem_read(ctrl.mem_read), .mem_write(ctrl.mem_write),
        .size(ctrl.mem_size), .is_unsigned(ctrl.mem_unsigned),
        .addr_offset(alu_result[1:0]), .store_data(rs2_data),
        .mem_rdata(dmem_rdata),
        .mem_re(lsu_re), .mem_wstrb(lsu_wstrb), .mem_wdata(lsu_wdata),
        .load_data(load_data), .misaligned(lsu_misaligned)
    );

    // Faults are checked before anything commits.
    always_comb begin
        active = !rst && !halted_q && !(DEBUG_ENABLE && debug_hold);
        fault_cause = STOP_NONE;
        if (ctrl.illegal)           fault_cause = STOP_ILLEGAL;
        else if (target_misaligned) fault_cause = STOP_MISALIGNED_FETCH;
        else if (lsu_misaligned)    fault_cause = ctrl.mem_write ? STOP_MISALIGNED_STORE
                                                                 : STOP_MISALIGNED_LOAD;
        fault  = active && (fault_cause != STOP_NONE);
        commit = active && !fault;
    end

    next_pc u_next_pc (
        .pc(pc), .rs1(rs1_data), .imm(imm), .jump(ctrl.jump),
        .branch_taken(branch_taken), .rst(rst), .hold(halted_q || fault || (DEBUG_ENABLE && debug_hold)),
        .pc_plus4(pc_plus4), .target(target), .redirect(redirect),
        .misaligned(target_misaligned), .next(pc_next)
    );

    always_comb begin
        case (ctrl.wb_sel)
            WB_MEM:  wb_data = load_data;
            WB_PC4:  wb_data = pc_plus4;
            default: wb_data = alu_result;
        endcase
        rd_we = commit && ctrl.reg_write && instr[11:7] != 5'd0;
    end

    // Memory ports. Side effects happen only for an instruction that commits.
    assign imem_addr  = pc_next;
    assign dmem_addr  = alu_result;
    assign dmem_re    = commit && lsu_re;
    assign dmem_wstrb = commit ? lsu_wstrb : 4'b0000;
    assign dmem_wdata = lsu_wdata;

    always_ff @(posedge clk) begin
        pc <= pc_next;
        if (rst) begin
            halted_q     <= 1'b0;
            stop_cause_q <= STOP_NONE;
        end else if (fault) begin
            halted_q     <= 1'b1;
            stop_cause_q <= fault_cause;
        end else if (commit && ctrl.halt != HALT_NONE) begin
            halted_q     <= 1'b1;
            stop_cause_q <= (ctrl.halt == HALT_EBREAK) ? STOP_EBREAK : STOP_ECALL;
        end
    end

    assign halted     = halted_q;
    assign stop_cause = stop_cause_q;
    always_ff @(posedge clk) begin
        if(rst) begin
            debug_hold<=DEBUG_ENABLE; debug_break<=0; debug_step<=0;
            debug_last_pc<=0; debug_last_valid<=0;
        end else if(DEBUG_ENABLE) begin
            if(commit) begin debug_last_pc<=pc; debug_last_valid<=1; end
            if(debug_hold && !halted_q) begin
                if(debug_control.resume || debug_control.step) begin
                    if(breakpoint_at(pc) && !debug_control.bypass_break) debug_break<=1;
                    else begin debug_hold<=0; debug_break<=0; debug_step<=debug_control.step; end
                end
            end else if(commit && !halted_q) begin
                if(breakpoint_at(pc_next)) begin debug_hold<=1; debug_break<=1; debug_step<=0; end
                else if(debug_step || debug_control.halt) begin debug_hold<=1; debug_break<=0; debug_step<=0; end
            end
        end
    end
    always_comb begin
        debug_status='0;
        if(DEBUG_ENABLE) begin
            debug_status.stopped=rst || debug_hold || halted_q;
            debug_status.reset_held=rst;
            debug_status.breakpoint=debug_break;
            debug_status.last_pc_valid=debug_last_valid;
            debug_status.next_pc=pc; debug_status.last_pc=debug_last_pc;
            debug_status.reg_rdata=rs1_data;
            debug_status.alu_result=alu_result;
        end
    end

    always_comb begin
        retire.valid     = commit;
        retire.pc        = pc;
        retire.instr     = instr;
        retire.next_pc   = pc_next;
        retire.rd_we     = rd_we;
        retire.rd        = rd_we ? instr[11:7] : 5'd0;
        retire.rd_wdata  = rd_we ? wb_data : 32'd0;
        retire.mem_re    = dmem_re;
        retire.mem_wstrb = dmem_wstrb;
        retire.mem_addr  = (dmem_re || dmem_wstrb != 4'b0000) ? alu_result : 32'd0;
        retire.mem_wdata = (dmem_wstrb != 4'b0000) ? lsu_wdata : 32'd0;
    end

    // Decode fields kept for the pipeline's hazard unit; unused here.
    logic unused;
    assign unused = ^{ctrl.uses_rs1, ctrl.uses_rs2, target, redirect};
endmodule
