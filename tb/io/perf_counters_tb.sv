`timescale 1ns/1ps
module perf_counters_tb;
    logic clk = 0, rst = 1, running = 0, retire_valid = 0;
    logic [3:0] cycles, instret;
    int checks = 0;
    perf_counters #(.WIDTH(4)) dut (.*);
    always #5 clk <= ~clk;
    task automatic check(input logic run, retire, reset, input int c, i);
        @(negedge clk); running = run; retire_valid = retire; rst = reset;
        @(posedge clk); #1;
        assert (cycles === 4'(c) && instret === 4'(i))
            else $fatal(1, "counters run=%b retire=%b rst=%b expected %0d/%0d got %0d/%0d", run, retire, reset, c, i, cycles, instret);
        checks++;
    endtask
    initial begin
        check(0, 0, 1, 0, 0);
        check(0, 1, 0, 0, 0);
        for (int n = 1; n <= 20; n++) check(1, 1, 0, n % 16, n % 16);
        check(1, 0, 0, 5, 4);
        check(0, 1, 0, 5, 4);
        check(1, 1, 1, 0, 0);
        check(1, 1, 0, 1, 1);
        check(0, 0, 0, 1, 1);
        $display("PASS: active cycles, retirement, stopped state, reset priority and modular wrap (%0d checks)", checks);
        $finish;
    end
    initial begin #10000; $fatal(1, "TIMEOUT: counters"); end
endmodule
