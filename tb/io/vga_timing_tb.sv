`timescale 1ns/1ps
module vga_timing_tb;
    logic clk = 0, rst = 1;
    logic [9:0] x, y;
    logic visible, vblank, hsync, vsync;
    int rx = 0, ry = 0, active_pixels = 0, hs_low = 0, vs_low = 0;
    int checks = 0;
    vga_timing dut (.*);
    always #20 clk <= ~clk;
    initial begin
        repeat (3) @(negedge clk);
        assert (x == 0 && y == 0 && hsync && vsync) else $fatal(1, "VGA timing reset");
        rst = 0;
        for (int frame = 0; frame < 2; frame++) begin
            active_pixels = 0; hs_low = 0; vs_low = 0;
            for (int tick = 0; tick < 420000; tick++) begin
                assert (x == 10'(rx) && y == 10'(ry))
                    else $fatal(1, "coordinate %0d,%0d expected %0d,%0d", x, y, rx, ry);
                assert (visible == (rx < 640 && ry < 480) && vblank == (ry >= 480))
                    else $fatal(1, "visible/blank at %0d,%0d", rx, ry);
                assert (hsync == !(rx >= 656 && rx < 752) && vsync == !(ry >= 490 && ry < 492))
                    else $fatal(1, "porch/sync at %0d,%0d", rx, ry);
                active_pixels += int'(visible);
                hs_low += int'(!hsync);
                vs_low += int'(!vsync);
                checks++;
                if (++rx == 800) begin rx = 0; if (++ry == 525) ry = 0; end
                @(negedge clk);
            end
            assert (active_pixels == 307200 && hs_low == 96*525 && vs_low == 2*800)
                else $fatal(1, "frame pixel/sync counts");
        end
        // Reset in the middle of a frame, not just at power-up.
        repeat (777) @(negedge clk); rst = 1;
        @(negedge clk);
        assert (x == 0 && y == 0 && hsync && vsync) else $fatal(1, "mid-frame reset");
        $display("PASS: VGA two complete 800x525 frames, every porch/sync/coordinate, 307200 visible pixels and mid-frame reset (%0d checks)", checks);
        $finish;
    end
    initial begin #40000000; $fatal(1, "TIMEOUT: VGA timing"); end
endmodule
