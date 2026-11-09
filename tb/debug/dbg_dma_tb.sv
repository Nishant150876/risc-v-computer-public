`timescale 1ns/1ps
module dbg_dma_tb;
    import dbg_pkg::*;
    logic clk=0,rst=1,request_valid=0,request_ready,request_write=0,request_bist=0,response_valid,response_ready=0;
    logic [31:0] request_address=0,response_address,ram_a_addr,ram_b_addr,ram_b_wdata,ram_b_rdata,a_data;
    logic [7:0] request_size=1;
    logic [15:0] request_count=1,response_status,response_completed;
    logic [DBG_MAX_MEM_DATA*8-1:0] request_data='0,response_data;
    logic response_unknown,ram_a_en,ram_b_en,corrupt_read=0;
    logic [3:0] ram_b_wstrb;
    dbg_wb_request_t bus;
    dbg_wb_response_t bus_response;
    logic unused_memory;
    assign unused_memory=^{a_data,response_address,bus_response,bus};
    dbg_dma dut(.*);
    dbg_ram_arbiter u_owner (
        .clk(clk),.rst(rst),.cpu_safe(1'b1),.debug_claim(bus.debug_claim),.bist_claim(bus.bist_claim),
        .debug_grant(bus_response.debug_grant),.bist_grant(bus_response.bist_grant),.cpu_owns(bus_response.cpu_owns),
        .cpu_a_en(1'b0),.cpu_a_addr(32'd0),.cpu_b_en(1'b0),.cpu_b_addr(32'd0),.cpu_b_wdata(32'd0),.cpu_b_wstrb(4'd0),
        .ram_a_en(ram_a_en),.ram_a_addr(ram_a_addr),.ram_b_en(ram_b_en),.ram_b_addr(ram_b_addr),
        .ram_b_wdata(ram_b_wdata),.ram_b_wstrb(ram_b_wstrb),.ram_b_rdata(ram_b_rdata^(corrupt_read ? 32'd1 : 32'd0)),
        .fault_enable(bus.fault_enable),.fault_address(bus.fault_address),.fault_mask(bus.fault_mask),
        .fault_fired(bus_response.fault_fired),.fault_original(bus_response.fault_original),.fault_observed(bus_response.fault_observed),
        .wb_cyc(bus.cyc),.wb_stb(bus.stb),.wb_we(bus.we),.wb_adr(bus.address),.wb_dat_w(bus.data),
        .wb_sel(bus.select_bytes),.wb_bist(bus.bist),.wb_ack(bus_response.ack),.wb_err(bus_response.error),.wb_dat_r(bus_response.data));
    ram memory(.clk(clk),.a_en(ram_a_en),.a_addr(ram_a_addr),.a_rdata(a_data),
        .b_en(ram_b_en),.b_addr(ram_b_addr),.b_wdata(ram_b_wdata),.b_wstrb(ram_b_wstrb),.b_rdata(ram_b_rdata));
    always #5 clk<=~clk;
    task automatic transfer(input logic writing,input logic [31:0] address,input logic [7:0] size,
                            input logic [15:0] count,status);
        @(negedge clk); wait(request_ready);
        request_write=writing; request_address=address; request_size=size; request_count=count; request_valid=1;
        @(negedge clk); request_valid=0;
        wait(response_valid); @(negedge clk);
        assert(response_status==status && !response_unknown && bus_response.cpu_owns)
            else $fatal(1,"DMA status %h expected%h",response_status,status);
        if(status==DBG_ST_OK) begin
            assert(response_completed==count) else $fatal(1,"DMA completed count");
            for(int b=0;b<int'(size)*int'(count);b=b+1)
                assert(response_data[b*8+:8]==request_data[b*8+:8]) else $fatal(1,"DMA readback byte %0d",b);
        end
        response_ready=1; @(negedge clk); response_ready=0; @(negedge clk);
    endtask
    initial begin
        for(int i=0;i<DBG_MAX_MEM_DATA;i=i+1) request_data[i*8+:8]=8'(i^32'h5a);
        memory.mem[13312]=32'ha5a5a5a5;
        repeat(4) @(negedge clk); rst=0;
        transfer(1,32'hd001,1,7,DBG_ST_OK); transfer(0,32'hd001,1,7,DBG_ST_OK);
        assert(memory.mem[13312][7:0]==8'ha5) else $fatal(1,"DMA byte destroyed neighbor");
        transfer(1,32'hd010,2,12,DBG_ST_OK); transfer(0,32'hd010,2,12,DBG_ST_OK);
        transfer(1,32'hd040,4,48,DBG_ST_OK); transfer(0,32'hd040,4,48,DBG_ST_OK);
        transfer(1,32'hd001,2,1,DBG_ST_ALIGNMENT);
        transfer(0,32'hffff,2,1,DBG_ST_ALIGNMENT);
        transfer(0,32'hfffc,4,2,DBG_ST_BAD_ADDRESS);
        transfer(1,32'h80000000,1,1,DBG_ST_BAD_ADDRESS);
        transfer(0,0,3,1,DBG_ST_BAD_ARGUMENT);
        transfer(0,0,4,49,DBG_ST_BAD_ARGUMENT);
        corrupt_read=1; transfer(1,32'hd100,4,1,DBG_ST_VERIFY_FAILED);
        assert(response_completed==0) else $fatal(1,"failed verification counted complete");
        corrupt_read=0; request_bist=1; transfer(1,32'hd100,4,1,DBG_ST_OK);
        $display("PASS: bounded debug/BIST DMA actual RAM byte/half/word writes + readback, max192 bytes, untouched lanes, no alias/wrap, verified element counts and mismatch detection");
        $finish;
    end
    initial begin #2000000; $fatal(1,"TIMEOUT debug DMA"); end
endmodule
