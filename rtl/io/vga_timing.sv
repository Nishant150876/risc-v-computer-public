`timescale 1ns/1ps

// 640x480, 800x525 total. 25 MHz gives 59.5238 Hz (25.175 MHz: 59.94 Hz).
// Coordinates start with the visible area; both syncs are active low.
module vga_timing (
    input logic clk,
    input logic rst,
    output logic [9:0] x, y,
    output logic visible, vblank,
    output logic hsync, vsync
);
    always_ff @(posedge clk) begin
        if (rst) begin
            x <= '0;
            y <= '0;
        end else if (x == 799) begin
            x <= '0;
            y <= y == 524 ? 10'd0 : y + 1'b1;
        end else x <= x + 1'b1;
    end
    assign visible = x < 640 && y < 480;
    assign vblank = y >= 480;
    assign hsync = !(x >= 656 && x < 752);
    assign vsync = !(y >= 490 && y < 492);
endmodule
