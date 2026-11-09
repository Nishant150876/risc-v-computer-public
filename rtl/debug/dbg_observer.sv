`timescale 1ns/1ps
// Actual architectural retirement, never a second CPU/reference model.
// Counter definition v1: cycles, instructions, loads, stores, branches, jumps.
// Captures include the retirement sampled on the capture/freeze edge.
module dbg_observer (
    input logic clk,rst,cpu_reset,running,
    input rv32i_pkg::retire_t retire,
    input rv32i_pkg::stop_cause_t stop_cause,
    input logic capture_counters,freeze_trace,arm_trace,clear_trace,
    output logic [31:0] counter_generation,trace_generation,
    output logic [511:0] counters,
    output logic [383:0] trace_descriptor,
    output logic trace_frozen,
    output logic [8:0] trace_count,
    input logic [7:0] read_index,
    output logic [255:0] read_record
);
    import rv32i_pkg::*;
    logic [63:0] cycles,instructions,loads,stores,branches,jumps;
    logic [63:0] cycles_next,instructions_next,loads_next,stores_next,branches_next,jumps_next;
    logic [63:0] order,overwritten;
    logic [31:0] epoch;
    logic [255:0] records[0:255];
    logic [7:0] head,read_address;
    logic [31:0] record_flags;
    logic previous_reset,armed,write_record;
    logic [8:0] count_next;
    logic [63:0] overwritten_next;
    assign write_record=armed && retire.valid && !cpu_reset;
    assign count_next=write_record && trace_count!=256 ? trace_count+1'b1 : trace_count;
    assign overwritten_next=overwritten+64'(write_record && trace_count==256);
    assign read_address=head-8'(trace_count)+read_index;
    always_comb begin
        cycles_next=cycles+64'(running && !cpu_reset);
        instructions_next=instructions+64'(retire.valid && !cpu_reset);
        loads_next=loads+64'(retire.valid && retire.mem_re && !cpu_reset);
        stores_next=stores+64'(retire.valid && |retire.mem_wstrb && !cpu_reset);
        branches_next=branches+64'(retire.valid && retire.instr[6:0]==7'b1100011 && !cpu_reset);
        jumps_next=jumps+64'(retire.valid && (retire.instr[6:0]==7'b1101111 || retire.instr[6:0]==7'b1100111) && !cpu_reset);
        record_flags='0;
        record_flags[0]=retire.rd_we; record_flags[5:1]=retire.rd;
        record_flags[6]=retire.mem_re; record_flags[10:7]=retire.mem_wstrb; record_flags[13:11]=stop_cause;
    end
    // No array reset and no reset on this read register: preserve synchronous RAM inference.
    always_ff @(posedge clk) begin
        if(write_record) records[head]<={record_flags,retire.mem_wdata,retire.mem_addr,retire.rd_wdata,
                                        retire.next_pc,retire.instr,retire.pc,32'(order)};
        read_record<=records[read_address];
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            cycles<=0; instructions<=0; loads<=0; stores<=0; branches<=0; jumps<=0;
            counter_generation<=0; trace_generation<=0; counters<=0; trace_descriptor<=0;
            order<=0; overwritten<=0; head<=0; trace_count<=0; armed<=0; trace_frozen<=0;
            epoch<=0; previous_reset<=1;
        end else begin
            previous_reset<=cpu_reset;
            if(cpu_reset) begin cycles<=0; instructions<=0; loads<=0; stores<=0; branches<=0; jumps<=0; end
            else begin cycles<=cycles_next; instructions<=instructions_next; loads<=loads_next;
                       stores<=stores_next; branches<=branches_next; jumps<=jumps_next; end
            if(retire.valid && !cpu_reset) order<=order+1'b1;
            if(cpu_reset && !previous_reset) begin
                epoch<=epoch+1'b1; head<=0; trace_count<=0; overwritten<=0; armed<=0; trace_frozen<=0;
                trace_generation<=trace_generation+1'b1;
            end else begin
                if(write_record) begin head<=head+1'b1; trace_count<=count_next; overwritten<=overwritten_next; end
                if(arm_trace) begin
                    armed<=1; trace_frozen<=0; trace_generation<=trace_generation+1'b1;
                    if(clear_trace) begin head<=0; trace_count<=0; overwritten<=0; end
                end
                if(freeze_trace) begin
                    armed<=0; trace_frozen<=1; trace_generation<=trace_generation+1'b1;
                    trace_descriptor<=0;
                    trace_descriptor[0+:32]<=trace_generation+1'b1;
                    trace_descriptor[32+:16]<=1; trace_descriptor[48+:16]<=32;
                    trace_descriptor[64+:16]<=16'(count_next); trace_descriptor[80+:16]<=256;
                    trace_descriptor[96+:32]<=32'd1 | (overwritten_next!=0 ? 32'd2 : 32'd0);
                    trace_descriptor[128+:64]<=order+64'(write_record)-{55'd0,count_next};
                    trace_descriptor[192+:64]<=order+64'(write_record)-(count_next==0 ? 64'd0 : 64'd1);
                    trace_descriptor[256+:64]<=overwritten_next; trace_descriptor[320+:32]<=epoch;
                end
            end
            if(capture_counters) begin
                counter_generation<=counter_generation+1'b1; counters<=0;
                counters[0+:16]<=1; counters[16+:8]<=64; counters[24+:8]<=6;
                counters[32+:32]<=counter_generation+1'b1;
                counters[64+:64]<=cpu_reset ? 64'd0 : cycles_next;
                counters[128+:64]<=cpu_reset ? 64'd0 : instructions_next;
                counters[192+:64]<=cpu_reset ? 64'd0 : loads_next;
                counters[256+:64]<=cpu_reset ? 64'd0 : stores_next;
                counters[320+:64]<=cpu_reset ? 64'd0 : branches_next;
                counters[384+:64]<=cpu_reset ? 64'd0 : jumps_next;
                counters[448+:32]<=epoch; counters[480+:8]<={7'd0,!running};
            end
        end
    end
endmodule
