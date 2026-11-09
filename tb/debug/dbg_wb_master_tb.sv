`timescale 1ns/1ps
module dbg_wb_master_tb;
    logic clk=0,rst=1,request_valid=0,request_ready,request_write=0,response_valid,response_ready=0;
    logic [31:0] request_address=0,request_data=0,response_data,wb_dat_w,wb_dat_r=32'hcafe1234;
    logic [3:0] request_select=15,wb_sel;
    logic response_error,response_timeout,outcome_unknown,wb_cyc,wb_stb,wb_we,wb_ack=0,wb_err=0;
    logic [29:0] wb_adr;
    dbg_wb_master #(.WATCHDOG_CYCLES(8)) dut(.*);
    always #5 clk<=~clk;
    task automatic begin_request(input logic writing,input logic [31:0] address);
        @(negedge clk); wait(request_ready); request_write=writing; request_address=address;
        request_data=32'h89abcdef; request_select=4'b1010; request_valid=1;
        @(negedge clk); request_valid=0;
    endtask
    task automatic consume;
        response_ready=1; @(negedge clk); response_ready=0; @(negedge clk);
    endtask
    initial begin
        logic [66:0] held;
        repeat(3) @(negedge clk); rst=0;
        begin_request(1,32'hd000);
        held={wb_we,wb_adr,wb_dat_w,wb_sel};
        repeat(4) begin @(negedge clk); assert(wb_cyc && wb_stb && {wb_we,wb_adr,wb_dat_w,wb_sel}==held) else $fatal(1,"Classic wait-state request changed"); end
        assert(wb_adr==30'h3400) else $fatal(1,"byte-to-word address conversion");
        wb_ack=1; @(negedge clk); wb_ack=0;
        assert(response_valid && !response_error && response_data==wb_dat_r && !wb_cyc) else $fatal(1,"Wishbone ACK");
        repeat(3) begin @(negedge clk); assert(response_valid && response_data==wb_dat_r) else $fatal(1,"reply backpressure"); end
        consume();
        begin_request(0,32'h40000000); wb_err=1; @(negedge clk); wb_err=0;
        assert(response_valid && response_error && !response_timeout && !outcome_unknown) else $fatal(1,"Wishbone ERR");
        consume();
        begin_request(1,32'hd004); wait(response_valid); @(negedge clk);
        assert(response_error && response_timeout && outcome_unknown && !wb_cyc) else $fatal(1,"uncertain timed-out write");
        consume();
        begin_request(0,32'hd004); wait(response_valid); @(negedge clk);
        assert(response_timeout && !outcome_unknown) else $fatal(1,"read watchdog");
        consume();
        begin_request(1,32'hd001);
        assert(response_valid && response_error && !wb_cyc && !outcome_unknown) else $fatal(1,"unaligned request reached bus");
        consume();
        begin_request(1,0); @(negedge clk); rst=1; @(negedge clk); rst=0;
        assert(!wb_cyc && !response_valid && request_ready) else $fatal(1,"reset did not abort cycle");
        $display("PASS: debug B4 Classic master stable wait states, word addressing/SEL, ACK/ERR, reset, watchdog and uncertain writes");
        $finish;
    end
    initial begin #100000; $fatal(1,"TIMEOUT Wishbone master"); end
endmodule
