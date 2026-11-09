`timescale 1ns/1ps

// Separate CPU and pixel domains, native CPU data bus (no access to main RAM).
// STATUS 0x80000028: bit0 displayed vblank; bit1 mode request pending;
//   bits3:2 last acknowledged mode. CONTROL 0x8000002c: bits1:0 requested
//   mode (0 text, 1 pixels, 2 color bars, 3 black). Lane-0 writes accepted
//   only while !pending. A toggle handshake holds the mode bus stable until
//   the pixel domain applies it at the first vertical-blank pixel.
// Pixel/sync pins are registered with the same four-edge display latency.
module vga #(
    parameter string FONT_FILE = "rtl/mem/font_rom.mem",
    parameter bit CPU_READ_POSEDGE = 1'b0
) (
    input logic clk, rst,
    input logic clk_pixel, rst_pixel,
    input logic en, re,
    input logic [3:0] wstrb,
    input logic [31:0] addr, wdata,
    output logic [31:0] regs_rdata, mem_rdata,
    output logic [3:0] red, green, blue,
    output logic hsync, vsync
);
    logic [9:0] x, y;
    logic visible, vblank, hs, vs;
    vga_timing u_timing (.clk(clk_pixel), .rst(rst_pixel), .x(x), .y(y),
                         .visible(visible), .vblank(vblank), .hsync(hs), .vsync(vs));

    logic text_select, fb_select;
    logic [31:0] text_rdata, fb_rdata;
    logic text_pixel;
    logic [3:0] fb_pixel;
    assign text_select = addr[31:12] == 20'h80010;
    assign fb_select = addr[31:14] == 18'h20008;
    vga_text #(.FONT_FILE(FONT_FILE), .CPU_READ_POSEDGE(CPU_READ_POSEDGE)) u_text (
        .clk(clk), .rst(rst), .cpu_en(en && text_select), .cpu_re(re),
        .cpu_addr(addr[11:0]), .cpu_wstrb(wstrb), .cpu_wdata(wdata), .cpu_rdata(text_rdata),
        .clk_pixel(clk_pixel), .rst_pixel(rst_pixel), .x(x), .y(y), .visible(visible), .pixel(text_pixel)
    );
    vga_fb #(.CPU_READ_POSEDGE(CPU_READ_POSEDGE)) u_fb (
        .clk(clk), .rst(rst), .cpu_en(en && fb_select), .cpu_re(re),
        .cpu_addr(addr[13:0]), .cpu_wstrb(wstrb), .cpu_wdata(wdata), .cpu_rdata(fb_rdata),
        .clk_pixel(clk_pixel), .rst_pixel(rst_pixel), .x(x), .y(y), .visible(visible), .pixel(fb_pixel)
    );
    logic read_fb;
    generate
        if (CPU_READ_POSEDGE) begin : g_read_rise
            always_ff @(posedge clk) begin
                if (rst) read_fb <= 0;
                else if (en && re) read_fb <= fb_select;
            end
        end else begin : g_read_fall
            always_ff @(negedge clk) begin
                if (rst) read_fb <= 0;
                else if (en && re) read_fb <= fb_select;
            end
        end
    endgenerate
    assign mem_rdata = read_fb ? fb_rdata : text_rdata;

    logic [1:0] requested_mode, applied_mode, mode_pixel;
    logic request_toggle, ack_toggle, ack_seen;
    (* ASYNC_REG = "TRUE" *) logic request_meta, request_sync;
    (* ASYNC_REG = "TRUE" *) logic ack_meta, ack_sync;
    (* ASYNC_REG = "TRUE" *) logic blank_meta, blank_sync;
    logic pending;
    logic [3:0] blank_pipe;
    assign pending = request_toggle != ack_seen;
    always_comb begin
        regs_rdata = '0;
        case ({addr[31:2], 2'b00})
            32'h8000_0028: regs_rdata = {28'b0, applied_mode, pending, blank_sync};
            32'h8000_002c: regs_rdata = {30'b0, requested_mode};
            default: ;
        endcase
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            ack_meta <= 0;
            ack_sync <= 0;
            ack_seen <= 0;
            blank_meta <= 0;
            blank_sync <= 0;
            requested_mode <= 2'd2;
            applied_mode <= 2'd2;
            request_toggle <= 0;
        end else begin
            ack_meta <= ack_toggle;
            ack_sync <= ack_meta;
            blank_meta <= blank_pipe[3];
            blank_sync <= blank_meta;
            if (ack_sync != ack_seen) begin
                applied_mode <= requested_mode;
                ack_seen <= ack_sync;
            end
            if (en && {addr[31:2], 2'b00} == 32'h8000_002c && wstrb[0] && !pending) begin
                requested_mode <= wdata[1:0];
                request_toggle <= ~request_toggle;
            end
        end
    end
    always_ff @(posedge clk_pixel) begin
        if (rst_pixel) begin
            request_meta <= 0;
            request_sync <= 0;
            ack_toggle <= 0;
            mode_pixel <= 2'd2;
        end else begin
            request_meta <= request_toggle;
            request_sync <= request_meta;
            if (x == 0 && y == 480 && request_sync != ack_toggle) begin
                mode_pixel <= requested_mode;
                ack_toggle <= request_sync;
            end
        end
    end

    function automatic logic [11:0] palette(input logic [3:0] index);
        case (index)
            0: return 12'h000; 1: return 12'h00a; 2: return 12'h0a0; 3: return 12'h0aa;
            4: return 12'ha00; 5: return 12'ha0a; 6: return 12'ha50; 7: return 12'haaa;
            8: return 12'h555; 9: return 12'h55f; 10: return 12'h5f5; 11: return 12'h5ff;
            12: return 12'hf55; 13: return 12'hf5f; 14: return 12'hff5; 15: return 12'hfff;
            default: return 12'h000;
        endcase
    endfunction
    function automatic logic [11:0] bars(input logic [9:0] px);
        if (px < 80) return 12'hfff;
        if (px < 160) return 12'hff0;
        if (px < 240) return 12'h0ff;
        if (px < 320) return 12'h0f0;
        if (px < 400) return 12'hf0f;
        if (px < 480) return 12'hf00;
        if (px < 560) return 12'h00f;
        return 12'h000;
    endfunction

    logic [2:0] visible_pipe, hs_pipe, vs_pipe;
    logic [1:0] mode_pipe [0:2];
    logic [11:0] bars_pipe [0:2];
    always_ff @(posedge clk_pixel) begin
        if (rst_pixel) begin
            visible_pipe <= '0;
            hs_pipe <= '1;
            vs_pipe <= '1;
            blank_pipe <= '0;
            for (int i = 0; i < 3; i++) begin
                mode_pipe[i] <= 2'd3;
                bars_pipe[i] <= '0;
            end
            red <= '0; green <= '0; blue <= '0;
            hsync <= 1; vsync <= 1;
        end else begin
            visible_pipe <= {visible_pipe[1:0], visible};
            hs_pipe <= {hs_pipe[1:0], hs};
            vs_pipe <= {vs_pipe[1:0], vs};
            blank_pipe <= {blank_pipe[2:0], vblank};
            mode_pipe[0] <= mode_pixel;
            bars_pipe[0] <= bars(x);
            for (int i = 1; i < 3; i++) begin
                mode_pipe[i] <= mode_pipe[i-1];
                bars_pipe[i] <= bars_pipe[i-1];
            end
            hsync <= hs_pipe[2];
            vsync <= vs_pipe[2];
            {red, green, blue} <= '0;
            if (visible_pipe[2]) begin
                case (mode_pipe[2])
                    0: {red, green, blue} <= text_pixel ? 12'hfff : 12'h000;
                    1: {red, green, blue} <= palette(fb_pixel);
                    2: {red, green, blue} <= bars_pipe[2];
                    default: ;
                endcase
            end
        end
    end
endmodule
