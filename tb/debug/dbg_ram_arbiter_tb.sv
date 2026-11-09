`timescale 1ns/1ps
module dbg_ram_arbiter_tb #(
    parameter bit PORTB_NEGEDGE=1
);
    logic clk=0,rst=1,cpu_safe=0,debug_claim=0,bist_claim=0,debug_grant,bist_grant,cpu_owns;
    logic cpu_a_en=1,cpu_b_en=0,ram_a_en,ram_b_en;
    logic [31:0] cpu_a_addr=0,cpu_b_addr=0,cpu_b_wdata=0,ram_a_addr,ram_b_addr,ram_b_wdata,ram_b_rdata,a_data;
    logic [3:0] cpu_b_wstrb=0,ram_b_wstrb;
    logic wb_cyc=0,wb_stb=0,wb_we=0,wb_bist=0,wb_ack,wb_err;
    logic [29:0] wb_adr=0;
    logic [31:0] wb_dat_w=0,wb_dat_r;
    logic [3:0] wb_sel=15;
    logic fault_enable=0,fault_fired;
    logic [31:0] fault_address=0,fault_mask=0,fault_original,fault_observed;
    int writes=0;
    logic unused_fetch_data;
    assign unused_fetch_data=^{a_data,fault_fired,fault_original,fault_observed};
    dbg_ram_arbiter dut(.*);
    ram #(.PORTB_NEGEDGE(PORTB_NEGEDGE)) memory (
        .clk(clk),.a_en(ram_a_en),.a_addr(ram_a_addr),.a_rdata(a_data),
        .b_en(ram_b_en),.b_addr(ram_b_addr),.b_wstrb(ram_b_wstrb),.b_wdata(ram_b_wdata),.b_rdata(ram_b_rdata));
    always #5 clk<=~clk;
    initial forever begin
        if(PORTB_NEGEDGE) @(negedge clk); else @(posedge clk);
        if(ram_b_en && (|ram_b_wstrb)) writes=writes+1;
    end
    task automatic transfer(input logic writing,input logic [31:0] address,data,
                            input logic [3:0] selects,input logic expect_error);
        assert(address[1:0]==0) else $fatal(1,"test transfer address must be aligned");
        @(negedge clk); wb_we=writing; wb_adr=address[31:2];
        wb_dat_w=data; wb_sel=selects; wb_cyc=1; wb_stb=1;
        do @(negedge clk); while(!wb_ack && !wb_err);
        assert(!(wb_ack && wb_err) && wb_err==expect_error) else $fatal(1,"RAM bus termination");
        repeat(3) begin @(negedge clk); assert(!wb_ack && !wb_err) else $fatal(1,"duplicate termination"); end
        wb_cyc=0; wb_stb=0; repeat(3) @(negedge clk);
    endtask
    initial begin
        repeat(3) @(negedge clk); rst=0; #1;
        assert(cpu_owns && ram_a_en) else $fatal(1,"CPU initial ownership");
        transfer(1,32'hd000,32'h12345678,15,1);
        assert(writes==0) else $fatal(1,"write accepted without ownership");
        debug_claim=1; repeat(8) @(negedge clk);
        assert(!debug_grant && cpu_owns && ram_a_en) else $fatal(1,"unsafe grant");
        cpu_safe=1; cpu_b_en=1; repeat(5) @(negedge clk);
        assert(!debug_grant) else $fatal(1,"outstanding CPU data operation was ignored");
        cpu_b_en=0; repeat(5) @(negedge clk);
        assert(debug_grant && !ram_a_en && !bist_grant) else $fatal(1,"fetch not disabled during lending");
        transfer(1,32'hd000,32'h12345678,15,0);
        assert(writes==1) else $fatal(1,"RAM write repeated %0d",writes);
        transfer(1,32'hd000,32'haabbccdd,4'b0101,0);
        transfer(0,32'hd000,0,15,0);
        assert(wb_dat_r==32'h12bb56dd && writes==2) else $fatal(1,"actual RAM readback/byte masks");
        transfer(1,32'h80000000,32'hffffffff,15,1);
        transfer(0,32'h00010000,0,15,1);
        assert(writes==2) else $fatal(1,"RAM address alias");
        bist_claim=1; wb_bist=1; transfer(1,32'hd004,32'hbadbad,15,1);
        debug_claim=0; repeat(8) @(negedge clk);
        assert(bist_grant && !debug_grant && !ram_a_en) else $fatal(1,"BIST ownership");
        transfer(1,32'hd004,32'h01020304,15,0);
        transfer(0,32'hd004,0,15,0); assert(wb_dat_r==32'h01020304) else $fatal(1,"BIST RAM path");
        bist_claim=0; repeat(5) @(negedge clk);
        assert(cpu_owns && ram_a_en && !ram_b_en) else $fatal(1,"CPU fetch-prime return");
        @(negedge clk); rst=1; @(negedge clk); assert(!ram_a_en && !ram_b_en) else $fatal(1,"reset memory gating");
        $display("PASS: RAM CPU/DEBUG/BIST exclusivity with real synchronous RAM, edge=%0d, byte masks, no alias, one write/cycle and fetch-prime return",PORTB_NEGEDGE);
        $finish;
    end
    initial begin #100000; $fatal(1,"TIMEOUT RAM ownership"); end
endmodule
