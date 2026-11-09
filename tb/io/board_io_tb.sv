`timescale 1ns/1ps
module board_io_tb;
    logic clk = 0, rst = 1, en = 0;
    logic [1:0] reg_sel = 0;
    logic [3:0] wstrb = 0;
    logic [31:0] wdata = 0, rdata;
    logic [15:0] switches = 0, led, display_value;
    logic [4:0] buttons = 0, buttons_clean;
    logic [6:0] seg;
    logic [3:0] an;
    logic dp;
    int checks = 0;
    board_io #(.CLK_HZ(40000), .SCAN_HZ(4000), .DEBOUNCE_CYCLES(3)) dut (.*);
    always #5 clk <= ~clk;

    function automatic logic [6:0] glyph(input logic [3:0] n);
        string lit [16] = '{"abcdef", "bc", "abdeg", "abcdg", "bcfg", "acdfg", "acdefg", "abc",
                             "abcdefg", "abcdfg", "abcefg", "cdefg", "adef", "bcdeg", "adefg", "aefg"};
        logic [6:0] result = '1;
        string segments = lit[n];
        for (int segment = 0; segment < 7; segment++)
            for (int c = 0; c < segments.len(); c++)
                if (segments[c] == 8'(97 + segment)) result[segment] = 0;
        return result;
    endfunction

    task automatic write_reg(input logic [1:0] regnum, input logic [31:0] value,
                             input logic [3:0] mask, input bit enabled = 1);
        @(posedge clk); #1;
        reg_sel = regnum; wdata = value; wstrb = mask; en = enabled;
        @(negedge clk); #1; en = 0; wstrb = 0;
    endtask
    initial begin
        repeat (2) @(negedge clk);
        #1; assert (led == 0 && display_value == 0) else $fatal(1, "board IO reset");
        @(posedge clk); #1; rst = 0;
        write_reg(0, 32'hffff_1234, 15);
        assert (led == 16'h1234) else $fatal(1, "LED word write");
        write_reg(0, 32'hffff_abcd, 1);
        assert (led == 16'h12cd) else $fatal(1, "LED low byte");
        write_reg(0, 32'hffff_abcd, 2);
        assert (led == 16'habcd) else $fatal(1, "LED high byte");
        write_reg(0, 0, 12);
        write_reg(0, 0, 15, 0);
        write_reg(2, 0, 15);
        assert (led == 16'habcd) else $fatal(1, "ignored write changed LEDs");
        @(negedge clk); switches = 16'ha53c; reg_sel = 2;
        @(posedge clk); #1;
        assert (rdata == 0) else $fatal(1, "switch synchronizer bypassed");
        @(posedge clk); #1;
        assert (rdata == 32'ha53c) else $fatal(1, "switch read");
        @(negedge clk); buttons = 5'b10110; reg_sel = 3;
        repeat (4) begin
            @(posedge clk); #1;
            assert (rdata == 0) else $fatal(1, "button debounce bypassed");
        end
        @(posedge clk); #1;
        assert (rdata == 32'h16 && buttons_clean == 5'h16) else $fatal(1, "button bit order/read");
        for (int n = 0; n < 16; n++) begin
            logic [15:0] word_value;
            for (int d = 0; d < 4; d++) word_value[d*4 +: 4] = 4'((n + d) % 16);
            write_reg(1, {16'b0, word_value}, 15);
            for (int sample = 0; sample < 44; sample++) begin
                int active_digit = -1;
                @(posedge clk); #1;
                for (int d = 0; d < 4; d++) if (!an[d]) active_digit = d;
                assert (active_digit >= 0 && an == ~(4'b1 << active_digit) && dp)
                    else $fatal(1, "anode selection/decimal point");
                assert (seg === glyph(4'((n + active_digit) % 16)))
                    else $fatal(1, "digit %0d value %h segments %b", active_digit, word_value, seg);
                checks++;
            end
        end
        write_reg(1, 32'hffff_0000, 12);
        assert (display_value == 16'h210f) else $fatal(1, "upper lanes changed hex register");
        @(posedge clk); #1; rst = 1;
        @(negedge clk); #1;
        assert (led == 0 && display_value == 0) else $fatal(1, "IO reset did not clear outputs");
        $display("PASS: board MMIO lanes, permissions, input synchronization/debounce and all hex glyphs/digits (%0d scan checks)", checks);
        $finish;
    end
    initial begin #100000; $fatal(1, "TIMEOUT: board IO"); end
endmodule
