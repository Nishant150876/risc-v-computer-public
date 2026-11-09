`timescale 1ns/1ps
module dbg_observer_tb;
    import rv32i_pkg::*;
    logic clk=0,rst=1,cpu_reset=0,running=0,capture_counters=0,freeze_trace=0,arm_trace=0,clear_trace=0;
    retire_t retire='0;
    stop_cause_t stop_cause=STOP_NONE;
    logic [31:0] counter_generation,trace_generation;
    logic [511:0] counters;
    logic [383:0] trace_descriptor;
    logic trace_frozen;
    logic [8:0] trace_count;
    logic [7:0] read_index=0;
    logic [255:0] read_record;
    logic unused_detail;
    assign unused_detail=^{counters,trace_descriptor,read_record};
    dbg_observer dut(.*);
    always #5 clk<=~clk;
    initial begin
        repeat(4) @(negedge clk); rst=0; running=1; arm_trace=1; clear_trace=1;
        @(negedge clk); arm_trace=0; clear_trace=0;
        for(int i=0;i<260;i=i+1) begin
            retire='0; retire.valid=1; retire.pc=32'(i*4); retire.next_pc=32'(i*4+4);
            retire.instr=32'h00000013; retire.rd_we=1; retire.rd=5'(i%31+1); retire.rd_wdata=32'(i);
            if(i==0) begin retire.mem_re=1; retire.instr=32'h00002083; end
            if(i==1) begin retire.mem_wstrb=15; retire.instr=32'h00102023; retire.mem_addr=256; retire.mem_wdata=42; end
            if(i==2) retire.instr=32'h00000063;
            if(i==3) retire.instr=32'h0000006f;
            if(i==259) begin capture_counters=1; freeze_trace=1; end
            @(negedge clk);
        end
        retire='0; capture_counters=0; freeze_trace=0;
        assert(trace_frozen && trace_count==256 && trace_generation==2 && counter_generation==1) else $fatal(1,"capture generations/count");
        assert(trace_descriptor[128+:64]==4 && trace_descriptor[192+:64]==259 && trace_descriptor[256+:64]==4)
            else $fatal(1,"overwritten descriptor");
        assert(counters[128+:64]==260 && counters[192+:64]==1 && counters[256+:64]==1 && counters[320+:64]==1 && counters[384+:64]==1)
            else $fatal(1,"actual event counter definitions");
        for(int i=0;i<256;i=i+1) begin
            read_index=8'(i); repeat(2) @(negedge clk);
            assert(read_record[0+:32]==32'(i+4) && read_record[32+:32]==32'((i+4)*4) && read_record[128+:32]==32'(i+4))
                else $fatal(1,"trace order/data at %0d",i);
        end
        assert(counters[128+:64]==260 && counter_generation==1) else $fatal(1,"counter capture changed while live");
        cpu_reset=1; repeat(4) @(negedge clk);
        assert(trace_generation==3 && trace_count==0 && !trace_frozen) else $fatal(1,"CPU reset stale trace generation");
        capture_counters=1; @(negedge clk); capture_counters=0;
        assert(counters[64+:64]==0 && counters[128+:64]==0 && counters[448+:32]==1) else $fatal(1,"reset epoch/counters");
        cpu_reset=0; retire.valid=1; capture_counters=1;
        dut.cycles=64'h00000000ffffffff; dut.instructions=64'hffffffffffffffff;
        @(negedge clk); capture_counters=0; retire.valid=0;
        assert(counters[64+:64]==64'h100000000 && counters[128+:64]==0 && counter_generation==3)
            else $fatal(1,"atomic carry across low32 and wrap64");
        $display("PASS: atomic 64-bit counters, real 32-byte retirement records, 256-record wrap/oldest ordering, explicit overwritten count, capture immutability and reset epoch/generation invalidation");
        $finish;
    end
    initial begin #100000; $fatal(1,"TIMEOUT observer"); end
endmodule
