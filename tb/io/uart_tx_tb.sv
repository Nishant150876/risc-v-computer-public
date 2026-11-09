`timescale 1ns/1ps
module uart_tx_tb;
    localparam int CPB = 217;
    localparam time BIT_TIME = CPB * 40;
    logic clk = 0, rst = 1, start = 0, tx, busy;
    logic [7:0] data = 0;
    int checks = 0;
    uart_tx #(.CLKS_PER_BIT(CPB)) dut (.*);
    always #20 clk <= ~clk;
    task automatic send(input logic [7:0] value);
        @(negedge clk); data = value; start = 1;
        @(negedge clk); start = 0; data = ~value;
        // A second request while busy must not replace or append a frame.
        repeat (CPB * 3) @(negedge clk);
        start = 1;
        @(negedge clk); start = 0;
        wait (!busy);
    endtask
    task automatic decode(input logic [7:0] expected);
        logic [7:0] observed;
        time began;
        @(negedge tx); began = $time;
        #(BIT_TIME / 2);
        assert (!tx && busy) else $fatal(1, "TX start bit");
        for (int b = 0; b < 8; b++) begin #(BIT_TIME); observed[b] = tx; end
        #(BIT_TIME);
        assert (tx && busy && observed === expected)
            else $fatal(1, "TX expected %h observed %h, stop=%b", expected, observed, tx);
        wait (!busy);
        assert ($time - began == 10 * BIT_TIME) else $fatal(1, "TX frame length");
        checks++;
    endtask
    initial begin
        repeat (3) @(negedge clk);
        assert (tx && !busy) else $fatal(1, "TX reset/idle");
        rst = 0;
        for (int n = 0; n < 256; n++) begin
            fork send(8'(n)); decode(8'(n)); join
            repeat (2) @(negedge clk);
            assert (tx && !busy) else $fatal(1, "busy request was queued unexpectedly");
        end
        @(negedge clk); start = 1; data = 0;
        @(negedge clk); start = 0;
        repeat (CPB * 2) @(negedge clk);
        rst = 1;
        @(posedge clk); #1;
        assert (tx && !busy) else $fatal(1, "TX reset did not abort a frame");
        $display("PASS: UART TX all 256 bytes, latched data, busy-write rejection, exact 217-clock bits and reset (%0d frames)", checks);
        $finish;
    end
    initial begin #30000000; $fatal(1, "TIMEOUT: UART TX"); end
endmodule
