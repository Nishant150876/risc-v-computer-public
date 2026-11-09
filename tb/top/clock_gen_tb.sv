`timescale 1ns/1ps
module clock_gen_tb;
    logic clk = 0, rst = 1, clk_cpu, clk_pixel, locked;
    time previous_edge;
    int checks = 0;
    clock_gen dut (.*);
    always #5 clk <= ~clk;
    initial begin
        repeat (3) @(negedge clk);
        assert (!locked && !clk_cpu) else $fatal(1, "clock manager reset");
        rst = 0;
        repeat (7) begin
            @(posedge clk); #1;
            assert (!locked) else $fatal(1, "simulation lock asserted too early");
        end
        @(posedge clk); #1;
        assert (locked) else $fatal(1, "simulation clock never locked");
        @(posedge clk_cpu); previous_edge = $time;
        repeat (12) begin
            @(posedge clk_cpu);
            assert ($time - previous_edge == 40) else $fatal(1, "CPU clock is not 25 MHz");
            assert (clk_pixel === clk_cpu) else $fatal(1, "25 MHz CPU/pixel clock mismatch");
            previous_edge = $time;
            checks++;
        end
        @(negedge clk); rst = 1;
        @(posedge clk); #1;
        assert (!locked && !clk_cpu) else $fatal(1, "clock reset did not clear simulated lock");
        $display("PASS: functional clock model lock, 40 ns period and reset; MMCM hardware requires separate Vivado checks (%0d period checks)", checks);
        $finish;
    end
    initial begin #10000; $fatal(1, "TIMEOUT: clock model"); end
endmodule
