`timescale 1ns/1ps
module hw_bist_tb;
    import dbg_pkg::*;
    import rv32i_pkg::*;
    logic clk=0,rst=1,start=0,abort_test=0,cpu_safe=1;
    logic [7:0] test_id=1,phase;
    logic [31:0] address=32'hd000,bytes=4096,completed,first_address,expected,observed,alu_a,alu_b,alu_result;
    logic ready,active,done,alu_test;
    logic [15:0] status;
    alu_op_t alu_op;
    dbg_wb_request_t bus,actual_bus;
    dbg_wb_response_t bus_response;
    cpu_debug_control_t debug_control;
    cpu_debug_status_t debug_status;
    retire_t retire;
    stop_cause_t stop_cause;
    logic mem_hold_ack,uart_tx_pin,dp,hs,vs,cpu_terminal,fault_enable=0;
    logic [31:0] fault_address=32'hd010,fault_mask=4,cycles,instret;
    logic [15:0] led,display_value;
    logic [6:0] seg;
    logic [3:0] an,red,green,blue;
    int fires=0;
    logic unused_outputs;
    assign unused_outputs=^{mem_hold_ack,uart_tx_pin,dp,hs,vs,led,display_value,seg,an,red,green,blue,
                           cycles,instret,retire,cpu_terminal,stop_cause,debug_status,bus_response};
    always_comb begin
        debug_control='0; debug_control.alu_test=alu_test; debug_control.alu_op=alu_op;
        debug_control.alu_a=alu_a; debug_control.alu_b=alu_b;
        actual_bus=bus; actual_bus.fault_enable=fault_enable;
        actual_bus.fault_address=fault_address; actual_bus.fault_mask=fault_mask;
    end
    assign alu_result=debug_status.alu_result;
    hw_bist dut(.*);
    soc #(.DEBUG_ENABLE(1),.DEBOUNCE_CYCLES(2)) system_under_test (
        .clk(clk),.rst(rst),.clk_pixel(clk),.rst_pixel(rst),.cpu_reset_req(1'b0),
        .mem_hold_req(1'b0),.mem_hold_ack(mem_hold_ack),.switches(16'd0),.buttons(5'd0),
        .uart_rx_pin(1'b1),.uart_tx_pin(uart_tx_pin),.led(led),.display_value(display_value),
        .seg(seg),.an(an),.dp(dp),.vga_red(red),.vga_green(green),.vga_blue(blue),
        .vga_hsync(hs),.vga_vsync(vs),.halted(cpu_terminal),.stop_cause(stop_cause),
        .retire(retire),.cycles(cycles),.instret(instret),.debug_reset_hold(1'b0),
        .debug_control(debug_control),.debug_status(debug_status),.debug_bus(actual_bus),.debug_bus_response(bus_response));
    always #5 clk<=~clk;
    initial forever begin @(posedge clk); if(bus_response.fault_fired) fires=fires+1; end
    task automatic run_test(input logic [7:0] id,input logic [31:0] base,size,input logic [15:0] result_status);
        @(negedge clk); wait(ready); test_id=id; address=base; bytes=size; start=1;
        @(negedge clk); start=0; wait(done); @(negedge clk);
        assert(status==result_status && !active && bus_response.cpu_owns) else $fatal(1,"BIST id%0d status%h expected%h",id,status,result_status);
    endtask
    initial begin
        system_under_test.u_ram.mem[13311]=32'h12345678; system_under_test.u_ram.mem[14336]=32'habcdef00;
        repeat(4) @(negedge clk); rst=0; repeat(6) @(negedge clk);
        run_test(1,32'hd000,4096,DBG_ST_OK);
        assert(completed==10240 && phase==5) else $fatal(1,"March C- phase/case count %0d/%0d",phase,completed);
        for(int i=13312;i<14336;i=i+1) assert(system_under_test.u_ram.mem[i]==0) else $fatal(1,"March final memory");
        assert(system_under_test.u_ram.mem[13311]==32'h12345678 && system_under_test.u_ram.mem[14336]==32'habcdef00) else $fatal(1,"BIST escaped scratch");
        run_test(2,0,0,DBG_ST_OK);
        assert(completed==16 && bus_response.cpu_owns) else $fatal(1,"actual CPU ALU vectors");
        run_test(1,0,4096,DBG_ST_BAD_ADDRESS); run_test(1,32'hd001,4,DBG_ST_ALIGNMENT);
        fault_enable=1; run_test(1,32'hd000,32,DBG_ST_VERIFY_FAILED);
        assert(fires==1 && first_address==32'hd010 && expected==0 && observed==4 && bus_response.fault_original==0 && bus_response.fault_observed==4)
            else $fatal(1,"read-path injected fault was not observed exactly once: %0d addr%h got%h",fires,first_address,observed);
        assert(system_under_test.u_ram.mem[13316]==0) else $fatal(1,"read XOR changed stored RAM");
        fault_enable=0; repeat(3) @(negedge clk);
        fault_enable=1; run_test(1,32'hd000,4,DBG_ST_OK);
        assert(fires==1) else $fatal(1,"fault hit an unselected address"); fault_enable=0;
        @(negedge clk); test_id=1; address=32'hd000; bytes=4096; start=1;
        @(negedge clk); start=0; repeat(30) @(negedge clk); abort_test=1;
        @(negedge clk); abort_test=0; wait(done); @(negedge clk);
        assert(status==DBG_ST_ABORTED && bus_response.cpu_owns && !active && !alu_test) else $fatal(1,"BIST abort did not drain/release");
        $display("PASS: real 4-KiB scratch RAM March C- 10240 cases, 16 known-answer vectors through actual CPU ALU, selected one-use hardware read XOR detection, confinement and drained abort");
        $finish;
    end
    initial begin #50000000; $fatal(1,"TIMEOUT hardware BIST"); end
endmodule
