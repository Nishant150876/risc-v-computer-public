`timescale 1ns/1ps
module dbg_uart_tb;
    import dbg_pkg::*;
    localparam time BIT_TIME=217*40;
    logic clk=0,rst=1,rx=1,tx,execute_valid,result_ready;
    dbg_frame_t execute_request;
    logic [DBG_MAX_PAYLOAD*8-1:0] identity_payload,status_payload='0;
    logic [31:0] rejected_frames,uart_overruns;
    logic [63:0] active_session;
    byte unsigned seen[$];
    logic unused_exec;
    assign unused_exec=^{execute_request,result_ready,active_session};
    assign identity_payload=dbg_identity(32'h54320001,62500000,DBG_CAP_BASE_STATUS,DBG_CPU_RESET_HELD);
    dbg_uart dut (
        .clk(clk),.rst(rst),.rx(rx),.tx(tx),.identity_payload(identity_payload),.status_payload(status_payload),
        .execute_valid(execute_valid),.execute_ready(1'b0),.execute_request(execute_request),
        .result_valid(1'b0),.result_ready(result_ready),.result_status(16'd0),.result_length(16'd0),
        .result_payload('0),.rejected_frames(rejected_frames),.uart_overruns(uart_overruns),.active_session(active_session));
    always #20 clk<=~clk;
`include "tb/debug/dbg_vectors.svh"
    initial forever begin
        logic [7:0] value;
        @(negedge tx); #(BIT_TIME/2);
        assert(!tx) else $fatal(1,"debug UART TX start");
        for(int i=0;i<8;i=i+1) begin #(BIT_TIME); value[i]=tx; end
        #(BIT_TIME); assert(tx) else $fatal(1,"debug UART TX stop");
        seen.push_back(value);
    end
    task automatic type_hex(input string value);
        for(int i=0;i<value.len()/2;i=i+1) begin
            logic [7:0] data;
            data=hex_byte(value,i); rx=0; #(BIT_TIME);
            for(int bit_index=0;bit_index<8;bit_index=bit_index+1) begin rx=data[bit_index]; #(BIT_TIME); end
            rx=1; #(BIT_TIME);
        end
    endtask
    initial begin
        int file,fields,commands=0;
        string line,kind,value;
        repeat(4) @(negedge clk); rst=0;
        file=$fopen("protocol/vectors/sessions.txt","r"); assert(file!=0) else $fatal(1,"session fixture missing");
        // First scenario is discovery; second claims, pings and reads status.
        while($fgets(line,file)!=0 && commands<4) begin
            fields=$sscanf(line,"%s %s",kind,value); if(fields<1) continue;
            if(kind=="send") type_hex(value);
            else if(kind=="expect") begin
                wait(seen.size()==value.len()/2);
                for(int i=0;i<seen.size();i=i+1)
                    assert(seen[i]==hex_byte(value,i)) else $fatal(1,"UART reply %0d byte%0d",commands,i);
                seen.delete(); commands=commands+1;
                // The wire test advances real milliseconds, unlike session fixtures.
                if(commands==1) begin @(negedge clk); rst=1; repeat(4) @(negedge clk); rst=0; end
            end
        end
        $fclose(file);
        assert(rejected_frames==0 && uart_overruns==0 && !execute_valid) else $fatal(1,"UART lost traffic");
        $display("PASS: dedicated 115200 8N1 debug UART discovery/claim/PING/STATUS exact wire bytes, no console sharing");
        $finish;
    end
    initial begin #100000000; $fatal(1,"TIMEOUT debug UART"); end
endmodule
