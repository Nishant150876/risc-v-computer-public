`timescale 1ns/1ps

// 2400 bytes, one unsigned character per 8x16 cell. CPU accesses are word
// aligned with native byte strobes. Bytes beyond 2399 read as zero/drop writes.
// RAM and font reads are synchronous. No reset loop touches either memory.
// Pixel output latency: three pixel edges, including the sampling edge.
module vga_text #(
    parameter string FONT_FILE = "rtl/mem/font_rom.mem",
    parameter bit CPU_READ_POSEDGE = 1'b0
) (
    input logic clk, rst,
    input logic cpu_en, cpu_re,
    input logic [11:0] cpu_addr,
    input logic [3:0] cpu_wstrb,
    input logic [31:0] cpu_wdata,
    output logic [31:0] cpu_rdata,
    input logic clk_pixel, rst_pixel,
    input logic [9:0] x, y,
    input logic visible,
    output logic pixel
);
    (* ram_style = "block" *) logic [31:0] chars [0:599];
    (* rom_style = "block" *) logic [7:0] font [0:4095];
    initial begin
        for (int i = 0; i < 600; i++) chars[i] = 32'h2020_2020;
        $readmemh(FONT_FILE, font);
    end

    logic unused_byte_offset;
    assign unused_byte_offset = ^cpu_addr[1:0];

    generate
        if (CPU_READ_POSEDGE) begin : g_cpu_rise
            always_ff @(posedge clk) begin
                if (rst) cpu_rdata <= '0;
                else if (cpu_en) begin
                    if (cpu_re) cpu_rdata <= cpu_addr[11:2] < 600 ? chars[cpu_addr[11:2]] : 32'b0;
                    if (cpu_addr[11:2] < 600)
                        for (int lane = 0; lane < 4; lane++)
                            if (cpu_wstrb[lane]) chars[cpu_addr[11:2]][lane*8 +: 8] <= cpu_wdata[lane*8 +: 8];
                end
            end
        end else begin : g_cpu_fall
            always_ff @(negedge clk) begin
                if (rst) cpu_rdata <= '0;
                else if (cpu_en) begin
                    if (cpu_re) cpu_rdata <= cpu_addr[11:2] < 600 ? chars[cpu_addr[11:2]] : 32'b0;
                    if (cpu_addr[11:2] < 600)
                        for (int lane = 0; lane < 4; lane++)
                            if (cpu_wstrb[lane]) chars[cpu_addr[11:2]][lane*8 +: 8] <= cpu_wdata[lane*8 +: 8];
                end
            end
        end
    endgenerate

    logic [11:0] cell_index;
    logic [31:0] word_q;
    logic [1:0] lane_q;
    logic [3:0] row_q;
    logic [2:0] col_q, col_qq;
    logic valid_q, valid_qq;
    logic [7:0] glyph_q;
    assign cell_index = 12'(y[9:4]) * 12'd80 + 12'(x[9:3]);
    // Reset only the validity/output pipeline, keeping RAM/ROM reads intact.
    // build.tcl also excludes these BRAMs from power-enable insertion: that
    // optimizer can look through the reset synchronizer and cause REQP-1839.
    // Clamp blanking coordinates to a real word; never read past the array.
    always_ff @(posedge clk_pixel) begin
        word_q <= chars[visible ? cell_index[11:2] : 10'b0];
        glyph_q <= font[{word_q[lane_q*8 +: 8], row_q}];
    end
    always_ff @(posedge clk_pixel) begin
        if (rst_pixel) begin
            lane_q <= '0;
            row_q <= '0;
            col_q <= '0;
            col_qq <= '0;
            valid_q <= 0;
            valid_qq <= 0;
            pixel <= 0;
        end else begin
            lane_q <= cell_index[1:0];
            row_q <= y[3:0];
            col_q <= x[2:0];
            valid_q <= visible;
            col_qq <= col_q;
            valid_qq <= valid_q;
            pixel <= valid_qq && glyph_q[3'd7 - col_qq];
        end
    end
endmodule
