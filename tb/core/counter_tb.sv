`timescale 1ns/1ps

module counter_tb;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic [3:0] count;
    int unsigned checks = 0;

    counter dut (
        .clk   (clk),
        .rst   (rst),
        .count (count)
    );

    always #5 clk <= ~clk;

    task automatic check_count(
        input logic [3:0] expected,
        input string description
    );
        @(negedge clk);
        assert (count === expected)
            else $fatal(1, "%s: expected %0d, got %0d",
                        description, expected, count);
        checks++;
    endtask

    initial begin
        // Exercise the same checker with a deliberately wrong expectation.
        // This mode must fail, proving that failures reach the calling task.
        if ($test$plusargs("force_failure")) begin
            $display("Intentional failure: expecting 1 while reset is active.");
            check_count(4'd1, "intentional reset mismatch");
            $fatal(1, "The intentional mismatch was not detected");
        end

        check_count(4'd0, "initial reset");
        check_count(4'd0, "held reset");
        rst = 1'b0;

        // Four-bit truncation gives an independent expected 0..15 sequence.
        // Twenty increments cross the 15 -> 0 wrap boundary.
        for (int unsigned step = 1; step <= 20; step++) begin
            check_count(4'(step), "counting and wraparound");
        end

        // Reset changes between rising edges; the counter must hold until
        // the next rising edge, then become zero.
        rst = 1'b1;
        #1;
        assert (count === 4'd4)
            else $fatal(1, "Reset changed count before a rising clock edge");
        checks++;
        check_count(4'd0, "reset after counting");

        rst = 1'b0;
        check_count(4'd1, "counting resumes after reset");

        $display("PASS: counter reset, counting, wraparound and restart (%0d checks)",
                 checks);
        $finish;
    end

    initial begin
        #1000;
        $fatal(1, "TIMEOUT: counter smoke test did not finish");
    end
endmodule
