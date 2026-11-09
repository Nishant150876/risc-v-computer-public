`timescale 1ns/1ps

// Five-stage pipelined RV32I CPU: IF, ID, EX, MEM, WB.
// cpu_single.sv stays the reference model; both CPUs share the decoder, ALU,
// immediate, branch, next-PC and load/store blocks and the retirement record.
//
// Memory (normal synchronous block RAM, both ports on the rising edge):
//   IF   imem_addr = fetch PC. At the rising edge the RAM output register
//        captures the instruction: it doubles as the IF/ID instruction
//        register. A stall holds imem_en low so that instruction stays put.
//   MEM  the EX/MEM register drives the data port for the whole cycle. Only a
//        valid instruction in MEM issues an access, exactly once (MEM never
//        stalls). Read data returns in WB.
//
// Hazards (DATA_HAZARDS = 1):
//   forward.sv   EX/MEM -> EX and MEM/WB -> EX for rs1, rs2 and store data.
//   regfile      BYPASS = 1 covers WB -> ID.
//   hazard.sv    load-use stalls one cycle; taken branch/JAL/JALR resolve in
//                EX and flush the two younger instructions (predict not-taken).
// DATA_HAZARDS = 0 is the first-pass configuration: no forwarding, no bypass,
// no load-use stall. Dependent instructions then need three instructions in
// between. Control flushes stay on in both configurations.
//
// Stop contract (same as cpu_single): faults are detected in EX, never
// retire and never issue a memory access; ECALL/EBREAK retire. Either one
// flushes the younger instructions, stops fetch and drains; halted rises at
// the edge on which the stopping instruction leaves WB. pc then holds the
// architectural PC: pc + 4 after ECALL/EBREAK, the faulting PC after a fault.
module cpu_pipe #(
    parameter bit DATA_HAZARDS = 1'b1
) (
    input  logic                      clk,
    input  logic                      rst,
    // Instruction port: synchronous read on the rising edge.
    output logic                      imem_en,
    output logic [31:0]               imem_addr,
    input  logic [31:0]               imem_rdata,
    // Data port: synchronous read/write on the rising edge; read data in WB.
    output logic                      dmem_re,
    output logic [3:0]                dmem_wstrb,
    output logic [31:0]               dmem_addr,
    output logic [31:0]               dmem_wdata,
    input  logic [31:0]               dmem_rdata,
    // Architectural observation.
    output rv32i_pkg::retire_t        retire,
    output logic                      halted,
    output rv32i_pkg::stop_cause_t    stop_cause
);
    import rv32i_pkg::*;

    // Pipeline registers.
    logic [31:0] fetch_pc;
    if_id_t      if_id;
    id_ex_t      id_ex;
    ex_mem_t     ex_mem;
    mem_wb_t     mem_wb;

    logic        stop_pending, halted_q;
    stop_cause_t stop_cause_q;
    // Architectural PC: next instruction to retire (the stop PC once halted).
    logic [31:0] pc;

    // Hazard control.
    logic load_use, stall, flush_id, bubble_ex, fetch_en, pc_hold;

    // ---------------------------------------------------------------- IF ----
    assign imem_addr = fetch_pc;
    assign imem_en   = fetch_en;

    // ---------------------------------------------------------------- ID ----
    logic [31:0] id_instr;
    control_t    id_ctrl;
    logic [31:0] id_imm, id_rs1_data, id_rs2_data;
    logic        rf_we;
    logic [31:0] wb_data;

    assign id_instr = imem_rdata;
    decoder u_decoder (.instr(id_instr), .ctrl(id_ctrl));
    imm_gen u_imm_gen (.instr(id_instr), .imm_sel(id_ctrl.imm_sel), .imm(id_imm));

    // The only architectural register writer: a retiring instruction in WB.
    regfile #(.BYPASS(DATA_HAZARDS)) u_regfile (
        .clk(clk), .we(rf_we), .waddr(mem_wb.rd), .wdata(wb_data),
        .raddr1(id_instr[19:15]), .raddr2(id_instr[24:20]),
        .rdata1(id_rs1_data), .rdata2(id_rs2_data)
    );

    // ---------------------------------------------------------------- EX ----
    fwd_sel_t    fwd_a, fwd_b;
    logic [31:0] ex_rs1, ex_rs2, op_a, op_b, alu_result;
    logic        branch_taken, redirect, target_misaligned;
    logic [31:0] pc_plus4, target, ex_next_pc;
    logic        lsu_re, lsu_misaligned;
    logic [3:0]  lsu_wstrb;
    logic [31:0] lsu_wdata, ex_unused_load;
    stop_cause_t ex_fault_cause;
    logic        ex_fault, ex_halt, ex_stop, ex_redirect;
    logic [4:0]  ex_rd;

    assign ex_rd = id_ex.instr[11:7];

    forward u_forward (
        .mem_valid(ex_mem.valid && DATA_HAZARDS), .mem_rd_we(ex_mem.rd_we), .mem_rd(ex_mem.rd),
        .wb_valid(mem_wb.valid && DATA_HAZARDS), .wb_rd_we(mem_wb.rd_we), .wb_rd(mem_wb.rd),
        .ex_rs1(id_ex.instr[19:15]), .ex_rs2(id_ex.instr[24:20]),
        .fwd_a(fwd_a), .fwd_b(fwd_b)
    );

    always_comb begin
        case (fwd_a)
            FWD_MEM: ex_rs1 = ex_mem.result;
            FWD_WB:  ex_rs1 = wb_data;
            default: ex_rs1 = id_ex.rs1_data;
        endcase
        case (fwd_b)
            FWD_MEM: ex_rs2 = ex_mem.result;
            FWD_WB:  ex_rs2 = wb_data;
            default: ex_rs2 = id_ex.rs2_data;
        endcase
        case (id_ex.ctrl.op_a_sel)
            OPA_PC:   op_a = id_ex.pc;
            OPA_ZERO: op_a = 32'd0;
            default:  op_a = ex_rs1;
        endcase
        op_b = (id_ex.ctrl.op_b_sel == OPB_IMM) ? id_ex.imm : ex_rs2;
    end

    alu u_alu (.a(op_a), .b(op_b), .op(id_ex.ctrl.alu_op), .result(alu_result));

    branch_unit u_branch (
        .a(ex_rs1), .b(ex_rs2), .branch(id_ex.ctrl.branch), .taken(branch_taken)
    );

    next_pc u_next_pc (
        .pc(id_ex.pc), .rs1(ex_rs1), .imm(id_ex.imm), .jump(id_ex.ctrl.jump),
        .branch_taken(branch_taken), .rst(1'b0), .hold(1'b0),
        .pc_plus4(pc_plus4), .target(target), .redirect(redirect),
        .misaligned(target_misaligned), .next(ex_next_pc)
    );

    // Store side of the LSU (lanes, strobes, alignment). Loads extend in WB.
    lsu u_lsu_ex (
        .mem_read(id_ex.ctrl.mem_read), .mem_write(id_ex.ctrl.mem_write),
        .size(id_ex.ctrl.mem_size), .is_unsigned(id_ex.ctrl.mem_unsigned),
        .addr_offset(alu_result[1:0]), .store_data(ex_rs2), .mem_rdata(32'd0),
        .mem_re(lsu_re), .mem_wstrb(lsu_wstrb), .mem_wdata(lsu_wdata),
        .load_data(ex_unused_load), .misaligned(lsu_misaligned)
    );

    // Same fault priority as cpu_single.
    always_comb begin
        ex_fault_cause = STOP_NONE;
        if (id_ex.ctrl.illegal)     ex_fault_cause = STOP_ILLEGAL;
        else if (target_misaligned) ex_fault_cause = STOP_MISALIGNED_FETCH;
        else if (lsu_misaligned)    ex_fault_cause = id_ex.ctrl.mem_write ? STOP_MISALIGNED_STORE
                                                                          : STOP_MISALIGNED_LOAD;
        ex_fault    = id_ex.valid && ex_fault_cause != STOP_NONE;
        ex_halt     = id_ex.valid && !ex_fault && id_ex.ctrl.halt != HALT_NONE;
        ex_stop     = ex_fault || ex_halt;
        ex_redirect = id_ex.valid && !ex_fault && redirect;
    end

    hazard u_hazard (
        .id_valid(if_id.valid && DATA_HAZARDS), .id_rs1(id_instr[19:15]), .id_rs2(id_instr[24:20]),
        .id_uses_rs1(id_ctrl.uses_rs1), .id_uses_rs2(id_ctrl.uses_rs2),
        .ex_valid(id_ex.valid), .ex_mem_read(id_ex.ctrl.mem_read), .ex_rd(ex_rd),
        .ex_redirect(ex_redirect), .ex_stop(ex_stop), .stop_pending(stop_pending),
        .load_use(load_use), .stall(stall), .flush_id(flush_id), .bubble_ex(bubble_ex),
        .fetch_en(fetch_en), .pc_hold(pc_hold)
    );

    // --------------------------------------------------------------- MEM ----
    // Only a valid instruction in MEM touches the bus. Faulting instructions
    // already carry no read enable and no strobes.
    assign dmem_re    = ex_mem.valid && ex_mem.mem_re;
    assign dmem_wstrb = ex_mem.valid ? ex_mem.mem_wstrb : 4'b0000;
    assign dmem_addr  = ex_mem.mem_addr;
    assign dmem_wdata = ex_mem.mem_wdata;

    // ---------------------------------------------------------------- WB ----
    logic [31:0] load_data;
    logic        wb_unused_re, wb_unused_misaligned;
    logic [3:0]  wb_unused_wstrb;
    logic [31:0] wb_unused_wdata;
    logic        wb_retires;

    lsu u_lsu_wb (
        .mem_read(1'b1), .mem_write(1'b0),
        .size(mem_wb.mem_size), .is_unsigned(mem_wb.mem_unsigned),
        .addr_offset(mem_wb.mem_addr[1:0]), .store_data(32'd0), .mem_rdata(dmem_rdata),
        .mem_re(wb_unused_re), .mem_wstrb(wb_unused_wstrb), .mem_wdata(wb_unused_wdata),
        .load_data(load_data), .misaligned(wb_unused_misaligned)
    );

    assign wb_data    = (mem_wb.wb_sel == WB_MEM) ? load_data : mem_wb.result;
    assign wb_retires = mem_wb.valid && !(mem_wb.stop inside {STOP_ILLEGAL, STOP_MISALIGNED_FETCH,
                                                            STOP_MISALIGNED_LOAD, STOP_MISALIGNED_STORE});
    assign rf_we      = wb_retires && mem_wb.rd_we;

    // ---------------------------------------------------- pipeline update ----
    ex_mem_t ex_out;
    always_comb begin
        ex_out.valid        = id_ex.valid;
        ex_out.pc           = id_ex.pc;
        ex_out.instr        = id_ex.instr;
        ex_out.next_pc      = ex_next_pc;
        ex_out.rd_we        = !ex_fault && id_ex.ctrl.reg_write && ex_rd != 5'd0;
        ex_out.rd           = ex_rd;
        ex_out.result       = (id_ex.ctrl.wb_sel == WB_PC4) ? pc_plus4 : alu_result;
        ex_out.wb_sel       = id_ex.ctrl.wb_sel;
        ex_out.mem_re       = !ex_fault && lsu_re;
        ex_out.mem_wstrb    = ex_fault ? 4'b0000 : lsu_wstrb;
        ex_out.mem_addr     = alu_result;
        ex_out.mem_wdata    = lsu_wdata;
        ex_out.mem_size     = id_ex.ctrl.mem_size;
        ex_out.mem_unsigned = id_ex.ctrl.mem_unsigned;
        ex_out.stop         = ex_fault ? ex_fault_cause
                            : ex_halt  ? ((id_ex.ctrl.halt == HALT_EBREAK) ? STOP_EBREAK : STOP_ECALL)
                            : STOP_NONE;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            fetch_pc     <= 32'h0000_0000;
            if_id        <= '0;
            id_ex        <= '0;
            ex_mem       <= '0;
            mem_wb       <= '0;
            stop_pending <= 1'b0;
            halted_q     <= 1'b0;
            stop_cause_q <= STOP_NONE;
            pc           <= 32'h0000_0000;
        end else begin
            // IF
            if (ex_redirect)  fetch_pc <= target;
            else if (!pc_hold) fetch_pc <= fetch_pc + 32'd4;
            // IF/ID (the instruction is the RAM output register)
            if (flush_id)     if_id.valid <= 1'b0;
            else if (!stall) begin
                if_id.valid <= 1'b1;
                if_id.pc    <= fetch_pc;
            end
            // ID/EX
            if (bubble_ex) id_ex.valid <= 1'b0;
            else begin
                id_ex.valid    <= if_id.valid;
                id_ex.pc       <= if_id.pc;
                id_ex.instr    <= id_instr;
                id_ex.ctrl     <= id_ctrl;
                id_ex.imm      <= id_imm;
                id_ex.rs1_data <= id_rs1_data;
                id_ex.rs2_data <= id_rs2_data;
            end
            // EX/MEM, MEM/WB: never stall.
            ex_mem <= ex_out;
            mem_wb <= ex_mem;
            if (ex_stop) stop_pending <= 1'b1;
            // Retirement and stop.
            if (wb_retires) pc <= mem_wb.next_pc;
            if (mem_wb.valid && mem_wb.stop != STOP_NONE) begin
                halted_q     <= 1'b1;
                stop_cause_q <= mem_wb.stop;
                if (!wb_retires) pc <= mem_wb.pc;
            end
        end
    end

    assign halted     = halted_q;
    assign stop_cause = stop_cause_q;

    always_comb begin
        retire.valid     = wb_retires;
        retire.pc        = mem_wb.pc;
        retire.instr     = mem_wb.instr;
        retire.next_pc   = mem_wb.next_pc;
        retire.rd_we     = rf_we;
        retire.rd        = rf_we ? mem_wb.rd : 5'd0;
        retire.rd_wdata  = rf_we ? wb_data : 32'd0;
        retire.mem_re    = wb_retires && mem_wb.mem_re;
        retire.mem_wstrb = wb_retires ? mem_wb.mem_wstrb : 4'b0000;
        retire.mem_addr  = (retire.mem_re || retire.mem_wstrb != 4'b0000) ? mem_wb.mem_addr : 32'd0;
        retire.mem_wdata = (retire.mem_wstrb != 4'b0000) ? mem_wb.mem_wdata : 32'd0;
    end

`ifndef SYNTHESIS
    // The hazard unit must never let a load's consumer reach EX while the
    // load is still in MEM: EX/MEM holds only the load address there.
    always_ff @(posedge clk) begin
        if (!rst && DATA_HAZARDS && id_ex.valid && ex_mem.valid && ex_mem.wb_sel == WB_MEM)
            assert (!(fwd_a == FWD_MEM && (id_ex.ctrl.uses_rs1)) &&
                    !(fwd_b == FWD_MEM && (id_ex.ctrl.uses_rs2)))
                else $error("load result forwarded from MEM before it exists");
        if (!rst && halted_q)
            assert (!if_id.valid && !id_ex.valid && !ex_mem.valid && !mem_wb.valid && !imem_en)
                else $error("halted pipeline is not empty");
    end
`endif

    logic unused;
    assign unused = ^{ex_unused_load, wb_unused_re, wb_unused_misaligned, wb_unused_wstrb,
                      wb_unused_wdata, load_use, pc};
endmodule
