`timescale 1ns/1ps
module basys3_soc_tb #(
    parameter bit PIPELINE = 1'b0  // 1: run the same checks on cpu_pipe
);
    logic clk = 0, btnC = 0, btnU = 0, btnL = 0, btnR = 0, btnD = 0, RsRx = 1;
    logic [15:0] sw = 16'h0014, led;
    logic RsTx, dp;
    logic [6:0] seg;
    logic [3:0] an;
    int checks = 0;
    logic [3:0] vgaRed, vgaGreen, vgaBlue;
    logic Hsync, Vsync;
    logic unused_vga_pins;
    assign unused_vga_pins = ^{vgaRed, vgaGreen, vgaBlue, Hsync, Vsync};

    basys3_soc #(.PIPELINE(PIPELINE), .INIT_FILE("tb/data/soc_tb.mem"), .DEBOUNCE_CYCLES(3)) dut (.*);
    always #5 clk <= ~clk;
    initial begin
        wait (dut.locked);
        @(posedge dut.clk_cpu); #1;
        assert (dut.rst) else $fatal(1, "reset released before synchronization");
        wait (dut.halted); #1;
        assert (led == 16'h14 && dut.display_value == 16'h14 && RsTx && dp)
            else $fatal(1, "board top integration: led=%h display=%h cause=%0d pc=%h", led, dut.display_value, dut.stop_cause, dut.u_soc.g_cpu.u_cpu.pc);
        @(negedge clk); btnC = 1; sw = 16'h000b;
        repeat (9) @(posedge dut.clk_cpu); #1;
        assert (!dut.halted && dut.locked && !dut.rst && led == 16'h14)
            else $fatal(1, "CPU button reset incorrectly reset clock/peripherals");
        @(negedge clk); btnC = 0;
        wait (dut.halted); #1;
        assert (led == 16'hb && dut.display_value == 16'hb) else $fatal(1, "board restart");
        repeat (20) begin
            @(posedge dut.clk_cpu); #1;
            assert (RsTx && dp && led == 16'hb && !$isunknown({seg, an}))
                else $fatal(1, "stopped board outputs");
            checks++;
        end
        $display("PASS: board top clock/reset startup, MMIO pins, CPU-only button restart and UART idle (%0d held-output checks)", checks);
        $finish;
    end
    initial begin #50000; $fatal(1, "TIMEOUT: board top"); end
endmodule
