`timescale 1ns/1ps

// Checks the Phase 0 blink top with a tiny divider (4 clocks per LED step):
// LEDs stay 0 in reset, every value lasts exactly 4 clocks, values step by 1,
// the full 16-bit count wraps from 0xFFFF to 0, and reset works mid-count.
module basys3_top_tb;
    localparam int DIV_BITS = 2;
    localparam int STEP     = 1 << DIV_BITS;

    logic        clk  = 1'b0;
    logic        btnC = 1'b1;
    logic [15:0] led;
    int unsigned checks = 0;

    basys3_top #(.DIV_BITS(DIV_BITS)) dut (
        .clk  (clk),
        .btnC (btnC),
        .led  (led)
    );

    always #5 clk <= ~clk;

    initial begin
        // Held reset: LEDs must read 0.
        repeat (6) @(negedge clk);
        assert (led === 16'd0) else $fatal(1, "LEDs not 0 in reset: %h", led);
        checks++;

        // Release reset and wait for the first step to 1.
        btnC = 1'b0;
        while (led === 16'd0) begin
            @(negedge clk);
        end
        assert (led === 16'd1) else $fatal(1, "first step went to %h, not 1", led);

        // Every value must last exactly STEP clocks and step by exactly 1,
        // all the way through the 0xFFFF -> 0x0000 wrap and back to 0x0010.
        for (int unsigned n = 1; n <= 32'h1_0010; n++) begin
            logic [15:0] expected;
            expected = 16'(n);
            for (int c = 0; c < STEP; c++) begin
                assert (led === expected)
                    else $fatal(1, "step %0d clock %0d: expected %h, got %h",
                                n, c, expected, led);
                @(negedge clk);
            end
            checks++;
        end
        assert (led === 16'h0011) else $fatal(1, "after wrap: expected 0011, got %h", led);
        checks++;

        // Reset mid-count: LEDs return to 0 within the synchronizer delay.
        btnC = 1'b1;
        repeat (3) @(negedge clk);
        assert (led === 16'd0) else $fatal(1, "reset mid-count left %h", led);
        checks++;

        $display("PASS: blink reset, %0d steps, 16-bit wrap and reset mid-count (%0d checks)",
                 32'h1_0010, checks);
        $finish;
    end

    initial begin
        #10_000_000;
        $fatal(1, "TIMEOUT: blink test did not finish");
    end
endmodule
