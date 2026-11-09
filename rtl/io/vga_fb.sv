`timescale 1ns/1ps

// 160x120x4 bpp, little-endian: leftmost pixel in bits 3:0, eight pixels
// per CPU word. A byte strobe writes two pixels. CPU readback supports
// read-modify-write of a single nibble. Offset 9600..16383 is reserved/zero.
// Each logical pixel covers 4x4 screen pixels. Three pixel edges of latency.
module vga_fb #(
    parameter bit CPU_READ_POSEDGE = 1'b0
) (
    input logic clk, rst,
    input logic cpu_en, cpu_re,
    input logic [13:0] cpu_addr,
    input logic [3:0] cpu_wstrb,
    input logic [31:0] cpu_wdata,
    output logic [31:0] cpu_rdata,
    input logic clk_pixel, rst_pixel,
    input logic [9:0] x, y,
    input logic visible,
    output logic [3:0] pixel
);
    (* ram_style = "block" *) logic [31:0] pixels [0:2399];
    initial for (int i = 0; i < 2400; i++) pixels[i] = '0;
    logic unused_subpixel_bits;
    assign unused_subpixel_bits = ^{cpu_addr[1:0], x[1:0], y[1:0]};
    generate
        if (CPU_READ_POSEDGE) begin : g_cpu_rise
            always_ff @(posedge clk) begin
                if (rst) cpu_rdata <= '0;
                else if (cpu_en) begin
                    if (cpu_re) cpu_rdata <= cpu_addr[13:2] < 2400 ? pixels[cpu_addr[13:2]] : 32'b0;
                    if (cpu_addr[13:2] < 2400)
                        for (int lane = 0; lane < 4; lane++)
                            if (cpu_wstrb[lane]) pixels[cpu_addr[13:2]][lane*8 +: 8] <= cpu_wdata[lane*8 +: 8];
                end
            end
        end else begin : g_cpu_fall
            always_ff @(negedge clk) begin
                if (rst) cpu_rdata <= '0;
                else if (cpu_en) begin
                    if (cpu_re) cpu_rdata <= cpu_addr[13:2] < 2400 ? pixels[cpu_addr[13:2]] : 32'b0;
                    if (cpu_addr[13:2] < 2400)
                        for (int lane = 0; lane < 4; lane++)
                            if (cpu_wstrb[lane]) pixels[cpu_addr[13:2]][lane*8 +: 8] <= cpu_wdata[lane*8 +: 8];
                end
            end
        end
    endgenerate
    logic [14:0] pixel_index;
    logic [31:0] word_q;
    logic [2:0] lane_q;
    logic [3:0] color_q;
    logic valid_q, valid_qq;
    assign pixel_index = 15'(y[9:2]) * 15'd160 + 15'(x[9:2]);
    // Unconditional synchronous BRAM read: reset only the validity/output
    // pipeline, never the RAM read enable. See the text path's REQP-1839 note.
    always_ff @(posedge clk_pixel)
        word_q <= pixels[visible ? pixel_index[14:3] : 12'b0];
    always_ff @(posedge clk_pixel) begin
        if (rst_pixel) begin
            lane_q <= '0;
            color_q <= '0;
            valid_q <= 0;
            valid_qq <= 0;
            pixel <= '0;
        end else begin
            lane_q <= pixel_index[2:0];
            valid_q <= visible;
            color_q <= word_q[lane_q*4 +: 4];
            valid_qq <= valid_q;
            pixel <= valid_qq ? color_q : 4'b0;
        end
    end
endmodule
