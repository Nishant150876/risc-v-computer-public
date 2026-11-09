`timescale 1ns/1ps
// Hardware March C- over reserved scratch, or known answers through the actual
// halted CPU ALU mux. Each RAM write additionally receives verified readback.
// Full/program RAM destruction is intentionally unsupported by this profile.
module hw_bist (
    input logic clk,rst,start,abort_test,cpu_safe,
    input logic [7:0] test_id,
    input logic [31:0] address,bytes,
    output logic ready,active,done,
    output logic [15:0] status,
    output logic [7:0] phase,
    output logic [31:0] completed,first_address,expected,observed,
    output logic alu_test,
    output rv32i_pkg::alu_op_t alu_op,
    output logic [31:0] alu_a,alu_b,
    input logic [31:0] alu_result,
    output dbg_pkg::dbg_wb_request_t bus,
    input dbg_pkg::dbg_wb_response_t bus_response
);
    import dbg_pkg::*;
    import rv32i_pkg::*;
    typedef enum logic [3:0] {IDLE,MEM_SETUP,MEM_ISSUE,MEM_WAIT,ALU_SETUP,ALU_WAIT,ALU_CHECK,FINISH} state_t;
    state_t state;
    logic abort_pending,sub_write;
    logic [31:0] low_address,high_address,current_address,pattern,alu_expected;
    logic [4:0] vector_index;
    logic dma_valid,dma_ready,dma_write,dma_response,dma_unknown;
    logic [15:0] dma_status,dma_completed;
    logic [31:0] dma_error_address;
    logic [DBG_MAX_MEM_DATA*8-1:0] dma_data,dma_result;
    assign ready=state==IDLE;
    assign active=state!=IDLE;
    assign dma_valid=state==MEM_ISSUE && !abort_pending;
    assign alu_test=state==ALU_SETUP || state==ALU_WAIT || state==ALU_CHECK;
    logic unused_dma_detail;
    assign unused_dma_detail=^{dma_completed,dma_error_address,dma_unknown,dma_result};
    dbg_dma u_dma (
        .clk(clk),.rst(rst),.request_valid(dma_valid),.request_ready(dma_ready),.request_write(dma_write),
        .request_bist(1'b1),.request_address(current_address),.request_size(8'd4),.request_count(16'd1),
        .request_data(dma_data),.response_valid(dma_response),.response_ready(state==MEM_WAIT),
        .response_status(dma_status),.response_completed(dma_completed),.response_address(dma_error_address),
        .response_unknown(dma_unknown),.response_data(dma_result),.bus(bus),.bus_response(bus_response));
    always_comb begin
        alu_op=ALU_ADD; alu_a=0; alu_b=0; alu_expected=0;
        case(vector_index)
            0: begin alu_a=32'hffffffff; alu_b=1; alu_expected=0; end
            1: begin alu_a=32'h7fffffff; alu_b=1; alu_expected=32'h80000000; end
            2: begin alu_op=ALU_SUB; alu_b=1; alu_expected=32'hffffffff; end
            3: begin alu_op=ALU_SUB; alu_a=32'h80000000; alu_b=1; alu_expected=32'h7fffffff; end
            4: begin alu_op=ALU_AND; alu_a=32'hf0f00f0f; alu_b=32'h0ff0ff00; alu_expected=32'h00f00f00; end
            5: begin alu_op=ALU_OR; alu_a=32'hf0f00f0f; alu_b=32'h0ff0ff00; alu_expected=32'hfff0ff0f; end
            6: begin alu_op=ALU_XOR; alu_a=32'hf0f00f0f; alu_b=32'h0ff0ff00; alu_expected=32'hff00f00f; end
            7: begin alu_op=ALU_SLL; alu_a=1; alu_b=31; alu_expected=32'h80000000; end
            8: begin alu_op=ALU_SLL; alu_a=1; alu_b=32; alu_expected=1; end
            9: begin alu_op=ALU_SRL; alu_a=32'h80000000; alu_b=31; alu_expected=1; end
            10: begin alu_op=ALU_SRA; alu_a=32'h80000000; alu_b=31; alu_expected=32'hffffffff; end
            11: begin alu_op=ALU_SLT; alu_a=32'h80000000; alu_b=32'h7fffffff; alu_expected=1; end
            12: begin alu_op=ALU_SLT; alu_a=32'h7fffffff; alu_b=32'h80000000; alu_expected=0; end
            13: begin alu_op=ALU_SLTU; alu_a=32'hffffffff; alu_b=0; alu_expected=0; end
            14: begin alu_op=ALU_SLTU; alu_a=0; alu_b=32'hffffffff; alu_expected=1; end
            15: begin alu_op=ALU_SRA; alu_a=32'hf0000000; alu_b=4; alu_expected=32'hff000000; end
            default: begin end
        endcase
    end
    task automatic finish(input logic [15:0] result_status);
        status<=result_status; state<=FINISH;
    endtask
    task automatic next_address;
        completed<=completed+1'b1;
        if(phase==0 || phase==5 || sub_write) begin
            sub_write<=0;
            if((phase==3 || phase==4) ? current_address==low_address : current_address==high_address) begin
                if(phase==5) finish(DBG_ST_OK);
                else begin
                    phase<=phase+1'b1;
                    current_address<=(phase==2 || phase==3) ? high_address : low_address;
                    state<=MEM_SETUP;
                end
            end else begin
                current_address<=(phase==3 || phase==4) ? current_address-4 : current_address+4;
                state<=MEM_SETUP;
            end
        end else begin sub_write<=1; state<=MEM_SETUP; end
    endtask
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE; done<=0; status<=DBG_ST_OK; phase<=0; completed<=0;
            first_address<=0; expected<=0; observed<=0; abort_pending<=0; sub_write<=0;
            low_address<=0; high_address<=0; current_address<=0; pattern<=0;
            dma_write<=0; dma_data<=0; vector_index<=0;
        end else begin
            done<=0;
            if(abort_test || (active && !cpu_safe)) abort_pending<=1;
            case(state)
                IDLE: if(start) begin
                    completed<=0; first_address<=0; expected<=0; observed<=0; phase<=0;
                    status<=DBG_ST_ACCEPTED; abort_pending<=0; sub_write<=0; vector_index<=0;
                    if(!cpu_safe) finish(DBG_ST_BAD_STATE);
                    else if(test_id==2 && address==0 && bytes==0) state<=ALU_SETUP;
                    else if(test_id!=1) finish(DBG_ST_BAD_ARGUMENT);
                    else if(address[1:0]!=0 || bytes[1:0]!=0) finish(DBG_ST_ALIGNMENT);
                    else if(bytes==0 || address<32'hd000 || {1'b0,address}+{1'b0,bytes}>33'he000)
                        finish(DBG_ST_BAD_ADDRESS);
                    else begin low_address<=address; high_address<=address+bytes-4; current_address<=address; state<=MEM_SETUP; end
                end
                MEM_SETUP: begin
                    pattern<=(phase==2 || phase==4) ? 32'hffffffff : 32'd0;
                    dma_write<=phase==0 || (phase!=5 && sub_write);
                    dma_data<=0;
                    dma_data[0+:32]<=sub_write ? ((phase==2 || phase==4) ? 32'd0 : 32'hffffffff) : 32'd0;
                    state<=MEM_ISSUE;
                end
                MEM_ISSUE: if(abort_pending) finish(DBG_ST_ABORTED); else if(dma_ready) state<=MEM_WAIT;
                MEM_WAIT: if(dma_response) begin
                    if(abort_pending) finish(DBG_ST_ABORTED);
                    else if(dma_status!=DBG_ST_OK || (!dma_write && dma_result[0+:32]!=pattern)) begin
                        first_address<=current_address; expected<=dma_write ? dma_data[0+:32] : pattern;
                        observed<=dma_result[0+:32]; finish(dma_status==DBG_ST_OK ? DBG_ST_VERIFY_FAILED : dma_status);
                    end else next_address();
                end
                ALU_SETUP: if(abort_pending) finish(DBG_ST_ABORTED); else state<=ALU_WAIT;
                ALU_WAIT: state<=ALU_CHECK;
                ALU_CHECK: if(abort_pending) finish(DBG_ST_ABORTED);
                    else if(alu_result!=alu_expected) begin
                        first_address<={27'd0,vector_index}; expected<=alu_expected; observed<=alu_result; finish(DBG_ST_VERIFY_FAILED);
                    end else begin
                        completed<=completed+1'b1;
                        if(vector_index==15) finish(DBG_ST_OK); else begin vector_index<=vector_index+1'b1; state<=ALU_SETUP; end
                    end
                FINISH: begin done<=1; state<=IDLE; end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
