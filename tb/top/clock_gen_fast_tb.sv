`timescale 1ns/1ps
module clock_gen_fast_tb #(parameter int CPU_HZ = 50000000);
    localparam time CPU_PERIOD_NS = 64'd1000000000 / 64'(CPU_HZ);
    logic clk = 0, rst = 1, clk_cpu, clk_pixel, locked;
    time cpu_edge, pixel_edge;
    int cpu_checks = 0, pixel_checks = 0;
    clock_gen #(.CPU_HZ(CPU_HZ)) dut (.*);
    always #5 clk <= ~clk;
    initial begin
        repeat (3) @(negedge clk); rst = 0;
        wait (locked);
        fork
            begin
                @(posedge clk_cpu); cpu_edge = $time;
                repeat (20) begin
                    @(posedge clk_cpu);
                    assert ($time-cpu_edge == CPU_PERIOD_NS) else $fatal(1, "CPU clock model frequency %0d", CPU_HZ);
                    cpu_edge = $time; cpu_checks++;
                end
            end
            begin
                @(posedge clk_pixel); pixel_edge = $time;
                repeat (12) begin
                    @(posedge clk_pixel);
                    assert ($time-pixel_edge == 40) else $fatal(1, "pixel clock changed with CPU clock");
                    pixel_edge = $time; pixel_checks++;
                end
            end
        join
        @(negedge clk); rst = 1;
        @(negedge clk);
        assert (!clk_cpu && !clk_pixel && !locked) else $fatal(1, "dual-clock reset");
        $display("PASS: functional clock model CPU %0d Hz, pixels fixed at 25 MHz, lock/reset (%0d CPU and %0d pixel checks); hardware timing separate", CPU_HZ,cpu_checks,pixel_checks);
        $finish;
    end
    initial begin #10000; $fatal(1, "TIMEOUT: dual clock model"); end
endmodule
