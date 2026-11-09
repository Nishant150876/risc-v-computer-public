`timescale 1ns/1ps
module dbg_system_tb;
    import dbg_pkg::*;
    import rv32i_pkg::*;
    logic clk=0,rst=1;
    logic [31:0] now_ms=0,rejected_frames;
    logic rx_valid,rx_ready,tx_valid,tx_ready,abort_frame=0;
    logic [7:0] rx_data,tx_data;
    logic cpu_reset_req=0,console_rx=1,console_tx;
    logic [15:0] switches=0,led,display_value;
    logic [4:0] buttons=0;
    retire_t retire;
    dbg_frame_t request='0,response;
    logic request_valid=0,request_ready,request_busy,response_valid,decode_ready,decode_error;
    logic [7:0] error_code;
    int commands=0,retired=0,stores=0,ticks=0;
    logic [31:0] request_id=0,image_id,checksum;
    logic [31:0] words[0:5];
    logic [DBG_MAX_PAYLOAD*8-1:0] p;
    logic unused_outputs;
    assign unused_outputs=^{request_busy,decode_ready,error_code,console_tx,led,display_value,response,retire};
    dbg_system dut(.*);
    dbg_tx client_tx(.clk(clk),.rst(rst),.frame_valid(request_valid),.frame_ready(request_ready),.frame(request),
        .byte_valid(rx_valid),.byte_data(rx_data),.byte_ready(rx_ready),.busy(request_busy));
    dbg_rx #(.TIMEOUT_CYCLES(10000)) client_rx(.clk(clk),.rst(rst),.abort_frame(1'b0),
        .byte_valid(tx_valid && tx_ready),.byte_data(tx_data),.byte_ready(decode_ready),
        .frame_valid(response_valid),.frame(response),.error_valid(decode_error),.error_code(error_code));
    always #5 clk<=~clk;
    initial forever begin
        @(posedge clk);
        assert(!decode_error) else $fatal(1,"device sent invalid wire frame");
        if(retire.valid) begin retired=retired+1; if(|retire.mem_wstrb) stores=stores+1; end
        @(negedge clk); ticks=ticks+1; tx_ready=ticks%7!=3;
    end
    task automatic send_request(input logic replay,input logic [15:0] op,length,status,
                                input logic [DBG_MAX_PAYLOAD*8-1:0] payload);
        @(negedge clk); wait(request_ready);
        if(!replay) request_id=request_id+1'b1;
        request='0; request.version=DBG_PROTOCOL_VERSION; request.opcode=op; request.request_id=request_id;
        request.session_id=64'h1122334455667788; request.length=length; request.payload=payload;
        request_valid=1; @(negedge clk); request_valid=0;
        wait(response_valid); @(negedge clk);
        assert(response.status==status && response.request_id==request_id && response.session_id==request.session_id && response.opcode==op)
            else $fatal(1,"wire reply op%h status%h expected%h",op,response.status,status);
        commands=commands+1;
    endtask
    initial begin
        tx_ready=1;
        words[0]=32'h00100093; words[1]=32'h00208113; words[2]=32'h10202023;
        words[3]=32'h10002183; words[4]=32'h00000013; words[5]=32'h0000006f;
        checksum=32'hffffffff;
        for(int w=0;w<6;w=w+1) for(int b=0;b<4;b=b+1) checksum=dbg_crc_byte(checksum,words[w][b*8+:8]);
        checksum=~checksum;
        repeat(5) @(negedge clk); rst=0; repeat(8) @(negedge clk);
        send_request(0,DBG_OP_HELLO,0,DBG_ST_OK,'0);
        assert((response.payload[160+:32] & DBG_CAP_LOADER)!=0) else $fatal(1,"loader not advertised");
        p='0; p[64+:32]=24; p[96+:32]=checksum; p[128+:32]=32'h200; p[160+:32]=8;
        p[192+:32]=32'he000; p[224+:32]=32'h10000; p[256+:16]=1; p[272+:16]=1;
        send_request(0,DBG_OP_LOAD_BEGIN,40,DBG_ST_OK,p); image_id=response.payload[0+:32];
        p='0; p[0+:32]=image_id; p[64+:16]=24;
        for(int w=0;w<6;w=w+1) p[96+w*32+:32]=words[w];
        send_request(0,DBG_OP_LOAD_CHUNK,36,DBG_ST_OK,p);
        send_request(1,DBG_OP_LOAD_CHUNK,36,DBG_ST_OK,p);
        assert(response.payload[32+:32]==24) else $fatal(1,"chunk retry changed progress");
        p='0; p[0+:32]=image_id; send_request(0,DBG_OP_LOAD_COMMIT,4,DBG_ST_ACCEPTED,p);
        do begin send_request(0,DBG_OP_STATUS,0,DBG_ST_OK,'0); end while(response.payload[16+:8]==DBG_OPST_VERIFYING);
        assert(response.payload[26]) else $fatal(1,"verified image missing on wire");
        p='0; p[8+:8]=1; p[32+:32]=8; send_request(0,DBG_OP_BREAK_SET,8,DBG_ST_OK,p);
        p='0; p[0+:32]=image_id; send_request(0,DBG_OP_RUN,4,DBG_ST_OK,p);
        assert(retired==2 && stores==0) else $fatal(1,"wire load/run breakpoint");
        send_request(0,DBG_OP_STEP,0,DBG_ST_OK,'0);
        assert(retired==3 && stores==1) else $fatal(1,"wire store step");
        send_request(1,DBG_OP_STEP,0,DBG_ST_OK,'0);
        assert(retired==3 && stores==1) else $fatal(1,"lost-reply retry executed STEP twice");
        p='0; p[0+:8]=2; p[8+:8]=1; send_request(0,DBG_OP_REG_READ,4,DBG_ST_OK,p);
        assert(response.payload[64+:32]==3) else $fatal(1,"actual register over packet link");
        p='0; p[0+:32]=32'h100; p[32+:8]=4; p[48+:16]=1; send_request(0,DBG_OP_MEM_READ,8,DBG_ST_OK,p);
        assert(response.payload[64+:32]==3) else $fatal(1,"actual RAM over packet link");
        now_ms=2001;
        send_request(0,DBG_OP_STEP,0,DBG_ST_BAD_SESSION,'0);
        assert(retired==3 && stores==1) else $fatal(1,"expired session executed mutation");
        send_request(0,DBG_OP_HELLO,0,DBG_ST_OK,'0);
        send_request(0,DBG_OP_CPU_RESET,0,DBG_ST_OK,'0);
        assert(response.payload[0+:8]==DBG_CPU_RESET_HELD && response.payload[26]) else $fatal(1,"CPU reset lost session or verified RAM image");
        send_request(0,DBG_OP_PING,0,DBG_ST_OK,'0);
        assert(rejected_frames==0) else $fatal(1,"unexpected packet loss");
        $display("PASS: %0d end-to-end framed requests with byte backpressure: actual RAM load/CRC/BSS/run, pre-store break, register/memory reads, exactly-once store STEP and chunk retry, lease expiry and CPU reset link survival",commands);
        $finish;
    end
    initial begin #20000000; $fatal(1,"TIMEOUT framed debug system"); end
endmodule
