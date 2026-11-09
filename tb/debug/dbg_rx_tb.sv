`timescale 1ns/1ps
module dbg_rx_tb;
    import dbg_pkg::*;
    logic clk=0,rst=1,abort_frame=0,byte_valid=0,byte_ready,frame_valid,error_valid;
    logic [7:0] byte_data=0,error_code;
    dbg_frame_t frame,expected;
    dbg_frame_t frames[$];
    logic [7:0] errors[$];
    int checked=0;
    dbg_rx #(.TIMEOUT_CYCLES(1000)) dut (.*);
    always #5 clk<=~clk;
`include "tb/debug/dbg_vectors.svh"
    initial forever begin
        @(posedge clk); #1;
        if (frame_valid) frames.push_back(frame);
        if (error_valid) errors.push_back(error_code);
    end
    task automatic send_byte(input logic [7:0] value);
        @(negedge clk); wait(byte_ready); byte_data=value; byte_valid=1;
        @(negedge clk); byte_valid=0;
    endtask
    task automatic send_hex(input string value);
        for (int i=0;i<value.len()/2;i=i+1) send_byte(hex_byte(value,i));
    endtask
    task automatic reset_rx;
        @(negedge clk); rst=1; byte_valid=0; abort_frame=0;
        repeat(3) @(negedge clk); rst=0; frames.delete(); errors.delete();
    endtask
    initial begin
        int file,scanned;
        string line,kind,name,error_name,wire_hex;
        logic [7:0] observed;
        file=$fopen("protocol/vectors/frames.txt","r");
        assert(file!=0) else $fatal(1,"missing committed frame vectors");
        reset_rx();
        while ($fgets(line,file)!=0) begin
            scanned=$sscanf(line,"%s",kind);
            if(scanned!=1) continue;
            if(kind=="ok") begin
                reset_rx(); unpack_vector(line,expected,wire_hex); send_hex(wire_hex);
                repeat(350) @(negedge clk);
                assert(frames.size()==1 && errors.size()==0) else $fatal(1,"RX did not accept %s",line);
                assert(frames[0]===expected) else $fatal(1,"RX packet mismatch %s",line);
                checked++;
            end else if(kind=="err") begin
                reset_rx();
                scanned=$sscanf(line,"%s %s %s %s",kind,name,error_name,wire_hex);
                assert(scanned==4) else $fatal(1,"bad error vector");
                send_hex(wire_hex); send_byte(0); repeat(350) @(negedge clk);
                assert(errors.size()==1 && frames.size()==0) else $fatal(1,"RX did not reject %s",name);
                observed=errors.pop_front();
                assert(observed==error_number(error_name)) else $fatal(1,"%s: error %0d expected %s",name,observed,error_name);
                checked++;
            end
        end
        $fclose(file);
        // A partial packet times out; the first post-gap byte may start a new packet.
        reset_rx(); send_byte(8'h20); repeat(1002) @(negedge clk);
        assert(errors.size()==1 && errors[0]==DBG_ERR_TIMEOUT) else $fatal(1,"RX timeout");
        // UART framing failure discards through a delimiter; a reset clears it.
        @(negedge clk); abort_frame=1; @(negedge clk); abort_frame=0;
        send_byte(8'hff); send_byte(0); repeat(4) @(negedge clk);
        assert(byte_ready && frames.size()==0) else $fatal(1,"abort recovery");
        assert(checked==42) else $fatal(1,"frame fixture coverage %0d",checked);
        $display("PASS: debug RX 23 valid / 19 invalid golden frames, bounds, CRC/COBS priority, timeout and abort");
        $finish;
    end
    initial begin #3000000; $fatal(1,"TIMEOUT debug RX"); end
endmodule
