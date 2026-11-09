`timescale 1ns/1ps
module dbg_executor_tb;
    import dbg_pkg::*;
    import rv32i_pkg::*;
    logic clk=0,rst=1,execute_valid=0,execute_ready,result_valid,result_ready=0;
    logic [15:0] result_status,result_length;
    logic [DBG_MAX_PAYLOAD*8-1:0] result_payload,identity_payload,status_payload;
    dbg_frame_t execute_request='0;
    logic [63:0] active_session=64'h12345678;
    logic debug_reset_hold,cpu_terminal;
    cpu_debug_control_t debug_control;
    cpu_debug_status_t cpu;
    stop_cause_t stop_cause;
    dbg_wb_request_t bus;
    dbg_wb_response_t bus_response;
    retire_t retire;
    logic mem_hold_ack,uart_tx_pin,dp,hs,vs;
    logic [15:0] led,display_value;
    logic [6:0] seg;
    logic [3:0] an,red,green,blue;
    logic [31:0] cycles,instret;
    int retired=0,stores=0,commands=0;
    logic [31:0] image_id;
    logic [31:0] fault_id;
    logic [63:0] operation;
    logic [DBG_MAX_PAYLOAD*8-1:0] p;
    logic [31:0] words[0:5];
    logic unused_outputs;
    assign unused_outputs=^{result_payload,status_payload,identity_payload,mem_hold_ack,uart_tx_pin,dp,hs,vs,led,display_value,seg,an,red,green,blue,cycles,instret,retire};
    dbg_executor dut(.*);
    soc #(.DEBUG_ENABLE(1),.DEBOUNCE_CYCLES(2)) system_under_test (
        .clk(clk),.rst(rst),.clk_pixel(clk),.rst_pixel(rst),.cpu_reset_req(1'b0),
        .mem_hold_req(1'b0),.mem_hold_ack(mem_hold_ack),.switches(16'd0),.buttons(5'd0),
        .uart_rx_pin(1'b1),.uart_tx_pin(uart_tx_pin),.led(led),.display_value(display_value),
        .seg(seg),.an(an),.dp(dp),.vga_red(red),.vga_green(green),.vga_blue(blue),
        .vga_hsync(hs),.vga_vsync(vs),.halted(cpu_terminal),.stop_cause(stop_cause),
        .retire(retire),.cycles(cycles),.instret(instret),.debug_reset_hold(debug_reset_hold),
        .debug_control(debug_control),.debug_status(cpu),.debug_bus(bus),.debug_bus_response(bus_response));
    always #5 clk<=~clk;
    initial forever begin @(posedge clk); if(retire.valid) begin retired=retired+1; if(|retire.mem_wstrb) stores=stores+1; end end
    task automatic command(input logic [15:0] op,length,status,
                           input logic [DBG_MAX_PAYLOAD*8-1:0] payload);
        @(negedge clk); wait(execute_ready); execute_request='0;
        execute_request.opcode=op; execute_request.length=length; execute_request.payload=payload; execute_valid=1;
        @(negedge clk); execute_valid=0;
        wait(result_valid); @(negedge clk);
        assert(result_status==status) else $fatal(1,"op%h got %h expected%h state%0d pc%h",op,result_status,status,dut.state,cpu.next_pc);
        commands=commands+1;
        repeat(2) @(negedge clk);
        assert(result_valid) else $fatal(1,"executor lost held response");
        result_ready=1; @(negedge clk); result_ready=0;
    endtask
    function automatic logic [31:0] program_crc;
        logic [31:0] c;
        c=32'hffffffff;
        for(int w=0;w<6;w=w+1) for(int b=0;b<4;b=b+1) c=dbg_crc_byte(c,words[w][b*8+:8]);
        return ~c;
    endfunction
    task automatic begin_load(input logic [31:0] checksum);
        p='0; p[64+:32]=24; p[96+:32]=checksum; p[128+:32]=32'h200; p[160+:32]=16;
        p[192+:32]=32'he000; p[224+:32]=32'h10000; p[256+:16]=1; p[272+:16]=1;
        command(DBG_OP_LOAD_BEGIN,40,DBG_ST_OK,p); image_id=result_payload[0+:32];
        assert(image_id!=0 && !status_payload[26]) else $fatal(1,"load did not invalidate image");
    endtask
    task automatic chunk;
        p='0; p[0+:32]=image_id; p[64+:16]=24;
        for(int w=0;w<6;w=w+1) p[96+w*32+:32]=words[w];
        command(DBG_OP_LOAD_CHUNK,36,DBG_ST_OK,p);
        assert(result_payload[32+:32]==24) else $fatal(1,"chunk not verified/complete");
    endtask
    task automatic commit_image(input logic [15:0] expected_status);
        p='0; p[0+:32]=image_id; command(DBG_OP_LOAD_COMMIT,4,DBG_ST_ACCEPTED,p);
        operation=result_payload[0+:64];
        wait(!dut.operation_active); repeat(3) @(negedge clk);
        p='0; p[0+:64]=operation; command(DBG_OP_DIAG_RESULT,8,DBG_ST_OK,p);
        assert(result_payload[80+:16]==expected_status) else $fatal(1,"CRC operation result %h expected%h",result_payload[80+:16],expected_status);
        assert(status_payload[26]==(expected_status==DBG_ST_OK)) else $fatal(1,"image-valid state after CRC");
    endtask
    task automatic reg_value(input logic [7:0] index,input logic [31:0] value);
        p='0; p[0+:8]=index; p[8+:8]=1; command(DBG_OP_REG_READ,4,DBG_ST_OK,p);
        assert(result_length==12 && result_payload[64+:32]==value) else $fatal(1,"register%0d got%h expected%h",index,result_payload[64+:32],value);
    endtask
    initial begin
        words[0]=32'h00100093; words[1]=32'h00208113; words[2]=32'h10202023;
        words[3]=32'h10002183; words[4]=32'h00000013; words[5]=32'h0000006f;
        system_under_test.u_ram.mem[64]=32'ha5a5a5a5;
        for(int i=128;i<132;i=i+1) system_under_test.u_ram.mem[i]=32'hbadbadba;
        repeat(5) @(negedge clk); rst=0; repeat(8) @(negedge clk);
        command(DBG_OP_RUN,4,DBG_ST_IMAGE_INVALID,'0);
        begin_load(program_crc());
        p='0; p[0+:32]=image_id; command(DBG_OP_LOAD_COMMIT,4,DBG_ST_IMAGE_INVALID,p);
        chunk(); commit_image(DBG_ST_OK);
        for(int i=128;i<132;i=i+1) assert(system_under_test.u_ram.mem[i]==0) else $fatal(1,"BSS not zero/readback verified");
        p='0; p[64+:32]=24; p[96+:32]=program_crc(); p[128+:32]=32'h200; p[160+:32]=16;
        p[192+:32]=32'he000; p[224+:32]=32'h10000; p[256+:16]=1; p[272+:16]=1;
        p[304+:16]=2; p[320+:16]=16'hafc0; command(DBG_OP_LOAD_BEGIN,42,DBG_ST_BAD_ARGUMENT,p);
        p[304+:16]=1; p[320+:8]=8'hc2; command(DBG_OP_LOAD_BEGIN,41,DBG_ST_BAD_ARGUMENT,p);
        p[304+:16]=0; p[256+:16]=2; command(DBG_OP_LOAD_BEGIN,40,DBG_ST_BAD_ARGUMENT,p);
        assert(status_payload[26] && dut.load_id==image_id) else $fatal(1,"invalid metadata/name changed verified image");
        p='0; p[8+:8]=1; p[32+:32]=8; command(DBG_OP_BREAK_SET,8,DBG_ST_OK,p);
        p='0; p[0+:32]=1; command(DBG_OP_TRACE_ARM,4,DBG_ST_OK,p);
        p='0; p[0+:32]=image_id; command(DBG_OP_RUN,4,DBG_ST_OK,p);
        wait(cpu.stopped); repeat(4) @(negedge clk);
        assert(cpu.breakpoint && cpu.next_pc==8 && retired==2 && stores==0 && system_under_test.u_ram.mem[64]==32'ha5a5a5a5)
            else $fatal(1,"loaded CPU breakpoint pre-store pc%h retired%0d stores%0d",cpu.next_pc,retired,stores);
        reg_value(2,3);
        p='0; p[0+:8]=0; p[32+:32]=32'hffffffff; command(DBG_OP_REG_WRITE,8,DBG_ST_BAD_ARGUMENT,p); reg_value(0,0);
        p='0; p[0+:8]=2; p[32+:32]=32'h12345678; command(DBG_OP_REG_WRITE,8,DBG_ST_OK,p); reg_value(2,32'h12345678);
        command(DBG_OP_STEP,0,DBG_ST_OK,'0);
        assert(cpu.next_pc==12 && retired==3 && stores==1 && system_under_test.u_ram.mem[64]==32'h12345678) else $fatal(1,"store step side effects");
        command(DBG_OP_STEP,0,DBG_ST_OK,'0); reg_value(3,32'h12345678);
        command(DBG_OP_STEP,0,DBG_ST_OK,'0);
        assert(cpu.next_pc==20 && retired==5) else $fatal(1,"NOP step");
        p='0; p[0+:8]=1; p[8+:8]=1; p[32+:32]=20; command(DBG_OP_BREAK_SET,8,DBG_ST_OK,p);
        command(DBG_OP_RESUME,0,DBG_ST_OK,'0);
        assert(cpu.breakpoint && retired==5) else $fatal(1,"break before repeated-PC instruction");
        command(DBG_OP_RESUME,0,DBG_ST_OK,'0);
        assert(cpu.breakpoint && retired==6) else $fatal(1,"resume bypass must retire once");
        command(DBG_OP_COUNTERS_LATCH,0,DBG_ST_OK,'0);
        assert(result_payload[128+:64]==6 && result_payload[192+:64]==1 && result_payload[256+:64]==1 && result_payload[384+:64]==1)
            else $fatal(1,"linked actual CPU counters");
        command(DBG_OP_TRACE_FREEZE,0,DBG_ST_OK,'0);
        assert(result_payload[64+:16]==6 && result_payload[128+:64]==0 && result_payload[192+:64]==5) else $fatal(1,"trace descriptor");
        p='0; p[0+:32]=result_payload[0+:32]; p[64+:16]=6;
        command(DBG_OP_TRACE_READ,12,DBG_ST_OK,p);
        assert(result_length==204 && result_payload[96+2*256+32+:32]==8 &&
               result_payload[96+2*256+192+:32]==32'h12345678 && result_payload[96+2*256+224+7+:4]==15)
            else $fatal(1,"linked actual store trace");
        p[0+:32]=p[0+:32]-1'b1; command(DBG_OP_TRACE_READ,12,DBG_ST_NOT_FOUND,p);
        p='0; p[0+:32]=32'h100; p[32+:8]=4; p[48+:16]=1; command(DBG_OP_MEM_READ,8,DBG_ST_OK,p);
        assert(result_payload[64+:32]==32'h12345678) else $fatal(1,"RAM read is not actual CPU memory");
        p='0; p[0+:32]=32'h80000000; p[32+:8]=4; p[48+:16]=1; p[64+:32]=0;
        command(DBG_OP_MEM_WRITE,12,DBG_ST_BAD_ADDRESS,p);
        assert(status_payload[26]) else $fatal(1,"invalid address mutated valid image");
        p[0+:32]=32'h101; command(DBG_OP_MEM_WRITE,12,DBG_ST_ALIGNMENT,p);
        p[0+:32]=32'h104; p[64+:32]=32'hc0decafe; command(DBG_OP_MEM_WRITE,12,DBG_ST_OK,p);
        assert(system_under_test.u_ram.mem[65]==32'hc0decafe && status_payload[26] && status_payload[27]) else $fatal(1,"verified patch state");
        p='0; p[0+:8]=1; command(DBG_OP_BREAK_CLEAR,4,DBG_ST_OK,p);
        command(DBG_OP_RESUME,0,DBG_ST_OK,'0);
        p='0; p[0+:32]=32'hd010; p[32+:8]=4; p[48+:16]=1; p[64+:32]=0;
        command(DBG_OP_MEM_WRITE,12,DBG_ST_BAD_STATE,p);
        assert(status_payload[26] && bus_response.cpu_owns) else $fatal(1,"running edit changed image/ownership");
        command(DBG_OP_HALT,0,DBG_ST_OK,'0);
        assert(cpu.stopped && stores==1) else $fatal(1,"running HALT duplicated a store");
        p='0; p[0+:8]=2; command(DBG_OP_BIST_START,12,DBG_ST_ACCEPTED,p); operation=result_payload[0+:64];
        wait(!dut.operation_active); p='0; p[0+:64]=operation; command(DBG_OP_DIAG_RESULT,8,DBG_ST_OK,p);
        assert(result_payload[80+:16]==DBG_ST_OK && result_payload[96+:32]==16) else $fatal(1,"linked actual ALU BIST");
        p='0; p[0+:32]=32'hd010; p[32+:8]=4; p[48+:16]=1; p[64+:32]=32'hface0123;
        command(DBG_OP_MEM_WRITE,12,DBG_ST_OK,p);
        p='0; p[0+:8]=1; p[8+:8]=1; p[16+:16]=1; p[32+:32]=32'hd010; p[64+:32]=4;
        command(DBG_OP_INJECT_ARM,16,DBG_ST_OK,p); fault_id=result_payload[0+:32];
        p='0; p[0+:32]=fault_id; command(DBG_OP_INJECT_FIRE,4,DBG_ST_OK,p);
        command(DBG_OP_RESUME,0,DBG_ST_BAD_STATE,'0);
        p='0; p[0+:8]=1; p[32+:32]=32'hd000; p[64+:32]=32;
        command(DBG_OP_BIST_START,12,DBG_ST_ACCEPTED,p); operation=result_payload[0+:64];
        wait(!dut.operation_active); p='0; p[0+:64]=operation; command(DBG_OP_DIAG_RESULT,8,DBG_ST_OK,p);
        assert(result_payload[80+:16]==DBG_ST_VERIFY_FAILED && result_payload[128+:32]==32'hd010 && result_payload[192+:32]==4)
            else $fatal(1,"linked memory BIST did not detect hardware read fault");
        p='0; p[0+:32]=fault_id; command(DBG_OP_INJECT_RESULT,4,DBG_ST_OK,p);
        assert(result_payload[128+:32]==32'hface0123 && result_payload[160+:32]==0 && result_payload[192+:32]==4 &&
               result_payload[224+:32]==1 && result_payload[320+:16]==DBG_ST_OK) else $fatal(1,"fault evidence not actual/one-use");
        command(DBG_OP_INJECT_CLEAR,4,DBG_ST_OK,p); command(DBG_OP_INJECT_RESULT,4,DBG_ST_OK,p);
        assert(result_payload[336+:16]==DBG_ST_OK && result_payload[352+:32]==32'hface0123 && system_under_test.u_ram.mem[13316]==32'hface0123)
            else $fatal(1,"fault cleanup not real RAM restore/readback");
        command(DBG_OP_INJECT_FIRE,4,DBG_ST_BAD_STATE,p);
        p='0; p[0+:8]=1; p[32+:32]=32'hd000; p[64+:32]=32;
        command(DBG_OP_BIST_START,12,DBG_ST_ACCEPTED,p); operation=result_payload[0+:64];
        wait(!dut.operation_active); p='0; p[0+:64]=operation; command(DBG_OP_DIAG_RESULT,8,DBG_ST_OK,p);
        assert(result_payload[80+:16]==DBG_ST_OK && result_payload[96+:32]==80) else $fatal(1,"fault hook leaked into next March run");
        p='0; p[0+:8]=1; p[32+:32]=32'hd000; p[64+:32]=4096;
        command(DBG_OP_BIST_START,12,DBG_ST_ACCEPTED,p); operation=result_payload[0+:64];
        p='0; p[0+:64]=operation; command(DBG_OP_BIST_ABORT,8,DBG_ST_ACCEPTED,p);
        wait(!dut.operation_active); command(DBG_OP_DIAG_RESULT,8,DBG_ST_OK,p);
        assert(result_payload[80+:16]==DBG_ST_ABORTED && bus_response.cpu_owns) else $fatal(1,"linked BIST abort/drain");
        p='0; p[0+:8]=1; p[8+:8]=1; p[16+:16]=1; p[32+:32]=32'hd010; p[64+:32]=4;
        command(DBG_OP_INJECT_ARM,16,DBG_ST_OK,p); fault_id=result_payload[0+:32];
        p='0; p[0+:32]=fault_id; command(DBG_OP_INJECT_FIRE,4,DBG_ST_OK,p);
        command(DBG_OP_CPU_RESET,0,DBG_ST_OK,'0);
        p='0; command(DBG_OP_INJECT_RESULT,4,DBG_ST_OK,p);
        assert(!dut.fault_active && !dut.fault_armed && !dut.fault_restore_pending && result_payload[336+:16]==DBG_ST_ABORTED)
            else $fatal(1,"CPU-only reset left armed hooks or claimed restoration");
        begin_load(program_crc()^32'd1); chunk(); commit_image(DBG_ST_VERIFY_FAILED);
        p='0; p[0+:32]=image_id; command(DBG_OP_RUN,4,DBG_ST_IMAGE_INVALID,p);
        begin_load(program_crc()); chunk();
        // Corrupt actual RAM after the verified chunks. COMMIT must reread it.
        system_under_test.u_ram.mem[0]=words[0]^32'h1000; commit_image(DBG_ST_VERIFY_FAILED);
        begin_load(program_crc()); active_session=0; repeat(10) @(negedge clk);
        assert(!dut.loading && !status_payload[26]) else $fatal(1,"lease expiry left runnable partial image");
        active_session=1; begin_load(program_crc());
        p='0; p[0+:32]=image_id; command(DBG_OP_LOAD_ABORT,4,DBG_ST_OK,p);
        assert(!dut.loading && !status_payload[26]) else $fatal(1,"load abort");
        begin_load(program_crc()); command(DBG_OP_CPU_RESET,0,DBG_ST_OK,'0);
        assert(!dut.loading && dut.operation_state==DBG_OPST_FAILED && !status_payload[26]) else $fatal(1,"CPU reset left partial load in progress");
        begin_load(program_crc()); chunk(); p='0; p[0+:32]=image_id;
        command(DBG_OP_LOAD_COMMIT,4,DBG_ST_ACCEPTED,p); command(DBG_OP_LOAD_ABORT,4,DBG_ST_ACCEPTED,p);
        wait(!dut.operation_active); repeat(3) @(negedge clk);
        assert(dut.operation_status==DBG_ST_ABORTED && bus_response.cpu_owns && !status_payload[26]) else $fatal(1,"verification abort did not drain actual RAM and invalidate");
        $display("PASS: %0d executor commands on actual SoC: safe typed RAM, CRC reread, BSS, invalid/aborted loads, verified launch, pre-store/repeated-PC breakpoints, exact steps, x0/register edits",commands);
        $finish;
    end
    initial begin #15000000; $fatal(1,"TIMEOUT debug executor state%0d DMA%0d",dut.state,dut.u_dma.state); end
endmodule
