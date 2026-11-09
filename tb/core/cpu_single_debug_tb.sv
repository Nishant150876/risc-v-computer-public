`timescale 1ns/1ps
module cpu_single_debug_tb;
    import rv32i_pkg::*;
    logic clk=0,rst=1,halted,dmem_re;
    logic [31:0] imem_addr,imem_rdata,dmem_addr,dmem_wdata,dmem_rdata;
    logic [3:0] dmem_wstrb;
    retire_t retire;
    stop_cause_t stop_cause;
    cpu_debug_control_t debug_control='0;
    cpu_debug_status_t debug_status;
    int retired=0,writes=0;
    logic unused_retire_detail;
    assign unused_retire_detail=^{retire,debug_status};
    cpu_single #(.DEBUG_ENABLE(1)) dut(.*);
    ram memory(.clk(clk),.a_en(1'b1),.a_addr(imem_addr),.a_rdata(imem_rdata),
        .b_en(dmem_re || |dmem_wstrb),.b_addr(dmem_addr),.b_wdata(dmem_wdata),
        .b_wstrb(dmem_wstrb),.b_rdata(dmem_rdata));
    always #5 clk<=~clk;
    initial forever begin @(posedge clk); if(retire.valid) retired=retired+1; end
    initial forever begin @(negedge clk); if(|dmem_wstrb) writes=writes+1; end
    task automatic pulse(input logic stepping,input logic bypass);
        @(negedge clk); debug_control.step=stepping; debug_control.resume=!stepping;
        debug_control.bypass_break=bypass;
        @(negedge clk); debug_control.step=0; debug_control.resume=0; debug_control.bypass_break=0;
        @(negedge clk);
    endtask
    task automatic expect_stop(input int pc,count);
        int waited=0;
        while(!debug_status.stopped) begin
            @(negedge clk); waited=waited+1;
            if(waited>50) $fatal(1,"CPU did not drain/stop");
        end
        #1;
        assert(debug_status.next_pc==32'(pc) && retired==count) else $fatal(1,"stopped pc%h retired%0d expected%0d/%0d",debug_status.next_pc,retired,pc,count);
    endtask
    task automatic read_register(input logic [4:0] index,input logic [31:0] expected);
        @(negedge clk); debug_control.reg_addr=index;
        @(negedge clk); #1;
        assert(debug_status.reg_rdata==expected) else $fatal(1,"debug x%0d=%h expected%h raw_x1=%h raw_x2=%h raddr=%0d hold=%0d requested=%0d core=%0d",
            index,debug_status.reg_rdata,expected,dut.u_regfile.regs[1],dut.u_regfile.regs[2],dut.rf_raddr1,dut.debug_hold,debug_control.reg_addr,dut.debug_control.reg_addr);
    endtask
    initial begin
        memory.mem[0]=32'h00100093; memory.mem[1]=32'h00208113;
        memory.mem[2]=32'h10202023; memory.mem[3]=32'h10002183;
        memory.mem[4]=32'h00000013; memory.mem[5]=32'h0000006f;
        memory.mem[6]=32'h00100073; memory.mem[64]=32'ha5a5a5a5;
        repeat(4) @(negedge clk); rst=0;
        repeat(5) @(negedge clk); expect_stop(0,0);
        debug_control.breakpoint_enable=1; debug_control.breakpoint0=8;
        pulse(0,0); expect_stop(8,2);
        assert(debug_status.breakpoint && writes==0 && memory.mem[64]==32'ha5a5a5a5) else $fatal(1,"breakpoint occurred after store");
        read_register(2,3);
        debug_control.reg_we=1; debug_control.reg_addr=2; debug_control.reg_wdata=32'h12345678;
        @(negedge clk); debug_control.reg_we=0; read_register(2,32'h12345678);
        debug_control.reg_we=1; debug_control.reg_addr=0; debug_control.reg_wdata=32'hffffffff;
        @(negedge clk); debug_control.reg_we=0; read_register(0,0);
        pulse(1,1); expect_stop(12,3);
        assert(writes==1 && memory.mem[64]==32'h12345678 && debug_status.last_pc==8) else $fatal(1,"store step duplicated/lost");
        pulse(1,1); expect_stop(16,4); read_register(3,32'h12345678);
        debug_control.breakpoint_enable=3; debug_control.breakpoint1=20;
        pulse(1,1); expect_stop(20,5); read_register(0,0);
        assert(debug_status.breakpoint) else $fatal(1,"NOP/next breakpoint");
        pulse(0,1); expect_stop(20,6);
        assert(writes==1 && debug_status.last_pc==20) else $fatal(1,"resume bypass failed on repeated PC");
        debug_control.breakpoint_enable=0; pulse(0,0); repeat(5) @(negedge clk);
        debug_control.halt=1; @(negedge clk); debug_control.halt=0;
        expect_stop(20,retired); assert(writes==1) else $fatal(1,"halt duplicated a side effect");
        memory.mem[5]=32'h00100073; repeat(3) @(negedge clk);
        begin int before_count; before_count=retired; pulse(1,1); expect_stop(24,before_count+1); end
        assert(halted && stop_cause==STOP_EBREAK) else $fatal(1,"terminal step");
        begin int before_count; before_count=retired; pulse(0,1); expect_stop(24,before_count); end
        rst=1; memory.mem[0]=32'h0000000b; repeat(3) @(negedge clk); rst=0;
        begin int before_count; before_count=retired; pulse(1,1); expect_stop(0,before_count); end
        assert(halted && stop_cause==STOP_ILLEGAL && !debug_status.last_pc_valid && writes==1) else $fatal(1,"fault/reset semantics");
        read_register(2,32'h12345678);
        // Taken/not-taken branches and both jump forms complete one token;
        // wrong-path stores and breakpoints must never be admitted.
        begin
            int base_count;
            rst=1; debug_control.breakpoint_enable=3; debug_control.breakpoint0=8; debug_control.breakpoint1=20;
            memory.mem[0]=32'h00100093; memory.mem[1]=32'h00108463; memory.mem[2]=32'h10202023;
            memory.mem[3]=32'h00109463; memory.mem[4]=32'h008002ef; memory.mem[5]=32'h10202023;
            memory.mem[6]=32'h02400313; memory.mem[7]=32'h000303e7; memory.mem[8]=32'h10202023; memory.mem[9]=32'h00100073;
            repeat(3) @(negedge clk); rst=0; base_count=retired;
            pulse(1,1); expect_stop(4,base_count+1);
            pulse(1,1); expect_stop(12,base_count+2);
            assert(!debug_status.breakpoint) else $fatal(1,"wrong-path branch breakpoint");
            pulse(1,1); expect_stop(16,base_count+3);
            pulse(1,1); expect_stop(24,base_count+4); read_register(5,20);
            assert(!debug_status.breakpoint) else $fatal(1,"wrong-path JAL breakpoint");
            pulse(1,1); expect_stop(28,base_count+5);
            pulse(1,1); expect_stop(36,base_count+6); read_register(7,32);
            pulse(1,1); expect_stop(40,base_count+7);
            assert(halted && stop_cause==STOP_EBREAK && writes==1) else $fatal(1,"branch/jump step side effects");
            rst=1; memory.mem[0]=32'h00200093; memory.mem[1]=32'h00008167;
            repeat(3) @(negedge clk); rst=0; base_count=retired;
            pulse(1,1); expect_stop(4,base_count+1);
            pulse(1,1); expect_stop(4,base_count+1);
            assert(halted && stop_cause==STOP_MISALIGNED_FETCH && writes==1) else $fatal(1,"faulting JALR retired or stored");
        end
        $display("PASS: single-cycle debug boundary: pre-store breakpoints, exact load/store/NOP steps, one-instruction repeated-PC bypass, halt/resume, x0, register edits, termination/fault and reset preservation");
        $finish;
    end
    initial begin #100000; $fatal(1,"TIMEOUT CPU debug"); end
endmodule
