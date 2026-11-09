`timescale 1ns/1ps
module dbg_packet_tb;
    import dbg_pkg::*;
    logic clk=0,rst=1,abort_frame=0,rx_valid=0,rx_ready,tx_valid,tx_ready=1;
    logic [7:0] rx_data=0,tx_data;
    logic [31:0] now_ms=0,rejected_frames;
    logic [63:0] active_session;
    logic [DBG_MAX_PAYLOAD*8-1:0] identity_payload,status_payload='0;
    logic execute_valid,result_ready;
    dbg_frame_t execute_request;
    byte unsigned seen[$];
    int scenarios=0,replies=0,tick=0;
    logic unused_exec;
    assign unused_exec=^{execute_request,result_ready,active_session};
    assign identity_payload=dbg_identity(32'h54320001,62500000,DBG_CAP_BASE_STATUS,DBG_CPU_RESET_HELD);
    dbg_packet #(.TIMEOUT_CYCLES(10000)) dut (
        .clk(clk),.rst(rst),.now_ms(now_ms),.identity_payload(identity_payload),.status_payload(status_payload),
        .abort_frame(abort_frame),.rx_valid(rx_valid),.rx_data(rx_data),.rx_ready(rx_ready),
        .tx_valid(tx_valid),.tx_data(tx_data),.tx_ready(tx_ready),
        .execute_valid(execute_valid),.execute_ready(1'b0),.execute_request(execute_request),
        .result_valid(1'b0),.result_ready(result_ready),.result_status(16'd0),.result_length(16'd0),
        .result_payload('0),.rejected_frames(rejected_frames),.active_session(active_session));
    always #5 clk<=~clk;
`include "tb/debug/dbg_vectors.svh"
    initial forever begin
        @(posedge clk);
        if(tx_valid && tx_ready) seen.push_back(tx_data);
        assert(!execute_valid) else $fatal(1,"T2 must not execute unsupported commands");
        @(negedge clk); tick=tick+1; tx_ready=tick%5!=2;
    end
    task automatic reset_device;
        @(negedge clk); rst=1; rx_valid=0; now_ms=0;
        repeat(3) @(negedge clk); rst=0; seen.delete();
    endtask
    task automatic send_hex(input string value);
        for(int i=0;i<value.len()/2;i=i+1) begin
            @(negedge clk); wait(rx_ready); rx_data=hex_byte(value,i); rx_valid=1;
            @(negedge clk); rx_valid=0;
        end
    endtask
    task automatic expect_hex(input string value);
        int waited=0,expected_size;
        expected_size=value=="none" ? 0 : value.len()/2;
        if(expected_size==0) repeat(500) @(negedge clk);
        while(seen.size()<expected_size) begin
            @(negedge clk); waited=waited+1;
            if(waited>5000) $fatal(1,"packet reply timeout, got %0d expected %0d",seen.size(),expected_size);
        end
        repeat(12) @(negedge clk);
        assert(seen.size()==expected_size) else $fatal(1,"packet reply length %0d expected %0d",seen.size(),expected_size);
        for(int i=0;i<expected_size;i=i+1)
            assert(seen[i]==hex_byte(value,i)) else $fatal(1,"packet reply byte %0d got %h expected %h",i,seen[i],hex_byte(value,i));
        seen.delete(); replies=replies+1;
    endtask
    initial begin
        int file,fields,time_value;
        string line,kind,value;
        file=$fopen("protocol/vectors/sessions.txt","r");
        assert(file!=0) else $fatal(1,"missing committed session vectors");
        reset_device();
        while($fgets(line,file)!=0) begin
            fields=$sscanf(line,"%s %s",kind,value);
            if(fields<1 || kind=="#") continue;
            if(kind=="scenario") begin reset_device(); scenarios=scenarios+1; end
            else if(kind=="reset") reset_device();
            else if(kind=="at") begin
                fields=$sscanf(value,"%d",time_value);
                assert(fields==1 && time_value>=0) else $fatal(1,"invalid vector time");
                @(negedge clk); now_ms=32'(time_value);
            end else if(kind=="send") send_hex(value);
            else if(kind=="expect") expect_hex(value);
            else $fatal(1,"unknown session vector %s",line);
        end
        $fclose(file);
        assert(scenarios==11 && replies>25) else $fatal(1,"session coverage %0d/%0d",scenarios,replies);
        assert(dut.bad_frames==0 && dut.dropped_frames==0 &&
               rejected_frames==dut.rejected_requests) else $fatal(1,"unexpected framing/queue loss");
        $display("PASS: debug packet endpoint exact 11 committed session/replay scenarios, %0d replies; no Python oracle at runtime",replies);
        $finish;
    end
    initial begin #6000000; $fatal(1,"TIMEOUT debug packets"); end
endmodule
