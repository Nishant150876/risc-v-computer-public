`timescale 1ns/1ps
module debounce_tb;
    logic clk = 0, rst = 1;
    logic [1:0] async_in = 0, clean, quick;
    int checks = 0;
    debounce #(.WIDTH(2), .STABLE_CYCLES(3)) dut (.*);
    debounce #(.WIDTH(2), .STABLE_CYCLES(1)) fast_dut (
        .clk(clk), .rst(rst), .async_in(async_in), .clean(quick)
    );
    always #5 clk <= ~clk;
    task automatic tick(input logic [1:0] expected);
        @(posedge clk); #1;
        assert (clean === expected) else $fatal(1, "debounce expected %b, got %b", expected, clean);
        checks++;
    endtask
    initial begin
        tick(0); tick(0);
        @(negedge clk); rst = 0; async_in = 1;
        tick(0); tick(0); tick(0);
        assert (quick == 1) else $fatal(1, "one-cycle mode sync latency");
        tick(0); tick(1);
        // A one-cycle bounce cannot change the three-sample output.
        @(negedge clk); async_in = 0;
        tick(1);
        @(negedge clk); async_in = 1;
        repeat (6) tick(1);
        // The other button can settle while the first stays asserted.
        @(negedge clk); async_in = 3;
        repeat (4) tick(1);
        tick(3);
        @(negedge clk); async_in = 0;
        repeat (4) tick(3);
        tick(0);
        @(negedge clk); rst = 1; async_in = 3;
        tick(0); tick(0);
        assert (quick == 0) else $fatal(1, "reset did not clear quick mode");
        $display("PASS: debounce synchronization, exact sample threshold, independent buttons, bounce, release and reset (%0d checks)", checks);
        $finish;
    end
    initial begin #10000; $fatal(1, "TIMEOUT: debounce"); end
endmodule
