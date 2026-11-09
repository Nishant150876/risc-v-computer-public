`timescale 1ns/1ps
module soc_tb #(
    parameter bit PIPELINE = 1'b0  // 1: run the same checks on cpu_pipe
);
    import rv32i_pkg::*;
    cpu_debug_control_t debug_control='0;
    cpu_debug_status_t debug_status;
    dbg_pkg::dbg_wb_request_t debug_bus='0;
    dbg_pkg::dbg_wb_response_t debug_bus_response;
    logic debug_reset_hold=0,unused_debug_status;
    assign unused_debug_status=^{debug_status,debug_bus_response};
    logic clk = 0, rst = 1, cpu_reset_req = 0, mem_hold_req = 0, mem_hold_ack;
    logic [15:0] switches = 16'h0014, led, display_value;
    logic [4:0] buttons = 0;
    logic [6:0] seg;
    logic [3:0] an;
    logic dp, halted;
    logic uart_rx_pin = 1, uart_tx_pin;
    stop_cause_t stop_cause;
    retire_t retire;
    logic [31:0] cycles, instret;
    int checks = 0;
    wire clk_pixel = clk;
    wire rst_pixel = rst;
    logic [3:0] vga_red, vga_green, vga_blue;
    logic vga_hsync, vga_vsync;
    logic unused_vga_pins;
    assign unused_vga_pins = ^{vga_red, vga_green, vga_blue, vga_hsync, vga_vsync};

    soc #(.PIPELINE(PIPELINE), .INIT_FILE("tb/data/soc_tb.mem"), .SCAN_HZ(2500000), .DEBOUNCE_CYCLES(3)) dut (.*);
    always #20 clk <= ~clk;

    task automatic await_stop(input logic [15:0] value);
        wait (halted); #1;
        assert (stop_cause == STOP_EBREAK && led == value && display_value == value)
            else $fatal(1, "SoC stop=%0d led=%h display=%h expected %h", stop_cause, led, display_value, value);
        // The pipeline adds 4 fill cycles, plus one load-use stall while word 3
        // is still the original lw t1 (followed by sw t1).
        assert (instret == 7 && cycles == (!PIPELINE ? 7 : (dut.u_ram.mem[3][6:0] == 7'b0000011) ? 12 : 11))
            else $fatal(1, "SoC retirement/cycles %0d/%0d", instret, cycles);
        repeat (4) begin
            @(negedge clk); #1;
            assert (led == value && display_value == value && !dut.ram_en && dut.wstrb == 0 && !retire.valid)
                else $fatal(1, "post-halt side effect");
            checks++;
        end
    endtask
    initial begin
        repeat (3) @(posedge clk); #1; rst = 0;
        await_stop(16'h0014);
        // CPU-only reset keeps MMIO state and RAM, while resetting run counters.
        @(negedge clk); #1; cpu_reset_req = 1; switches = 7;
        repeat (4) @(posedge clk); #1;
        assert (!halted && cycles == 0 && instret == 0 && led == 16'h0014)
            else $fatal(1, "CPU reset changed peripheral state or did not reset CPU");
        assert (dut.u_ram.mem[0] == 32'h800002b7) else $fatal(1, "CPU reset erased RAM");
        cpu_reset_req = 0;
        await_stop(7);

        // Request ownership; acknowledgment requires quiet instruction/data ports.
        @(negedge clk); #1; mem_hold_req = 1;
        @(posedge clk); #1;
        assert (!mem_hold_ack) else $fatal(1, "ownership acknowledged without settling");
        @(posedge clk); #1;
        assert (mem_hold_ack && !dut.fetch_en && !dut.ram_en && !retire.valid)
            else $fatal(1, "reset-held ports not quiescent");
        repeat (4) begin
            @(negedge clk); #1;
            assert (mem_hold_ack && dut.wstrb == 0 && !dut.ram_en && led == 7)
                else $fatal(1, "CPU side effect during ownership hold");
            checks++;
        end
        // Bench-only replacement of instruction 4 while ports are disabled.
        // No runtime loader/debug write interface is exposed in Phase 3.
        dut.u_ram.mem[3] = 32'h00900313; // li t1, 9
        mem_hold_req = 0;
        @(posedge clk); #1;
        assert (!retire.valid && !mem_hold_ack) else $fatal(1, "CPU resumed before fetch prime");
        wait (retire.valid); #1;
        assert (retire.pc == 0 && retire.instr == 32'h800002b7)
            else $fatal(1, "restart executed a stale prefetched instruction");
        await_stop(9);

        // Debounced centre button restarts CPU without resetting display/clock.
        @(negedge clk); #1; buttons[0] = 1;
        repeat (8) @(posedge clk); #1;
        assert (!halted && instret == 0 && led == 9 && buttons[0]) else $fatal(1, "centre-button CPU reset");
        buttons[0] = 0;
        await_stop(9);

        // Acquire ownership while a store is poised for the falling edge,
        // rather than testing only an already-halted CPU. Reset-held ownership
        // cancels that not-yet-accepted write and preserves previous I/O.
        @(negedge clk); #1; mem_hold_req = 1;
        wait (mem_hold_ack); #1;
        dut.u_ram.mem[3] = 32'h00600313; // li t1, 6
        mem_hold_req = 0;
        // Single-cycle: the store at pc 16 executes while it retires. Pipeline:
        // it is poised in MEM, two instructions ahead of retirement.
        if (PIPELINE) wait (dut.wstrb == 4'b1111 && dut.addr == 32'h8000_0000);
        else wait (retire.valid && retire.pc == 16);
        #1;
        assert (dut.wstrb == 4'b1111 && led == 9 && display_value == 9)
            else $fatal(1, "active ownership case did not reach pending LED store");
        mem_hold_req = 1;
        wait (mem_hold_ack); #1;
        repeat (4) begin
            @(negedge clk); #1;
            assert (!dut.fetch_en && !dut.ram_en && dut.wstrb == 0 && !retire.valid &&
                    cycles == 0 && instret == 0 && led == 9 && display_value == 9)
                else $fatal(1, "pending CPU store escaped reset-held ownership");
            checks++;
        end
        dut.u_ram.mem[3] = 32'h00900313;
        mem_hold_req = 0;
        await_stop(9);

        // A branch outside the 64 KB RAM must fault, not execute an alias.
        @(negedge clk); #1; mem_hold_req = 1;
        wait (mem_hold_ack); #1;
        dut.u_ram.mem[0] = 32'h000102b7; // lui t0, 0x10
        dut.u_ram.mem[1] = 32'h00028067; // jalr zero, 0(t0)
        mem_hold_req = 0;
        wait (halted); #1;
        assert (stop_cause == STOP_ILLEGAL && dut.g_cpu.u_cpu.pc == 32'h10000 && instret == 2)
            else $fatal(1, "instruction range protection");
        $display("PASS: SoC MMIO execution, counters, reset separation, quiet ownership hold/fetch prime and invalid fetch (%0d quiet-cycle checks)", checks);
        $finish;
    end
    initial begin #50000; $fatal(1, "TIMEOUT: SoC"); end
    logic unused_display;
    assign unused_display = ^{seg, an, dp, retire, uart_tx_pin};
endmodule
