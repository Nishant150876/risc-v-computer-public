`timescale 1ns/1ps
module dbg_tx_tb;
    import dbg_pkg::*;
    logic clk=0,rst=1,frame_valid=0,frame_ready,byte_valid,byte_ready,busy;
    logic [7:0] byte_data;
    dbg_frame_t frame;
    byte unsigned bytes_seen[$];
    int tick=0,checked=0;
    logic stalled=0;
    logic [7:0] held_byte=0;
    dbg_tx dut (.*);
    always #5 clk<=~clk;
`include "tb/debug/dbg_vectors.svh"
    initial forever begin
        @(posedge clk);
        if(!rst) begin
            if(stalled) assert(byte_valid && byte_data==held_byte) else $fatal(1,"TX changed a stalled byte");
            stalled=byte_valid && !byte_ready; held_byte=byte_data;
            if(byte_valid && byte_ready) bytes_seen.push_back(byte_data);
        end
        @(negedge clk); tick=tick+1; byte_ready=tick%7!=1;
    end
    initial begin
        int file,scanned;
        string line,kind,wire_hex,name,data_hex,crc_hex;
        logic [31:0] crc,expected_crc;
        repeat(3) @(negedge clk); rst=0; frame='0; byte_ready=1;
        file=$fopen("protocol/vectors/frames.txt","r");
        assert(file!=0) else $fatal(1,"missing vectors");
        while($fgets(line,file)!=0) begin
            scanned=$sscanf(line,"%s",kind); if(scanned!=1) continue;
            if(kind=="crc") begin
                scanned=$sscanf(line,"%s %s %s %s",kind,name,data_hex,crc_hex);
                assert(scanned==4) else $fatal(1,"CRC fixture format");
                crc=32'hffffffff;
                if(data_hex!="-") for(int i=0;i<data_hex.len()/2;i=i+1) crc=dbg_crc_byte(crc,hex_byte(data_hex,i));
                scanned=$sscanf(crc_hex,"%h",expected_crc);
                assert(scanned==1 && ~crc==expected_crc) else $fatal(1,"CRC anchor %s",name);
            end else if(kind=="ok") begin
                bytes_seen.delete(); unpack_vector(line,frame,wire_hex);
                @(negedge clk); assert(frame_ready) else $fatal(1,"TX not ready"); frame_valid=1;
                @(negedge clk); frame_valid=0;
                wait(!busy); @(negedge clk);
                assert(bytes_seen.size()==wire_hex.len()/2) else $fatal(1,"TX size %0d expected %0d",bytes_seen.size(),wire_hex.len()/2);
                for(int i=0;i<bytes_seen.size();i=i+1)
                    assert(bytes_seen[i]==hex_byte(wire_hex,i)) else $fatal(1,"TX byte %0d: %s",i,line);
                checked++;
            end
        end
        $fclose(file);
        assert(checked==23) else $fatal(1,"TX fixture coverage");
        $display("PASS: debug TX exact 23 golden frames, CRC anchors and arbitrary byte backpressure");
        $finish;
    end
    initial begin #2000000; $fatal(1,"TIMEOUT debug TX"); end
endmodule
