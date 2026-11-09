`timescale 1ns/1ps
module vga_fb_tb;
    logic clk = 0, clk_pixel = 0, rst = 1, rst_pixel = 1;
    logic cpu_en = 0, cpu_re = 0, visible = 0;
    logic [13:0] cpu_addr = 0;
    logic [3:0] cpu_wstrb = 0;
    logic [31:0] cpu_wdata = 0, fall_data, rise_data;
    logic [9:0] x = 0, y = 0;
    logic [3:0] fall_pixel, rise_pixel;
    logic [31:0] model [2400];
    int checks = 0;
    vga_fb #(.CPU_READ_POSEDGE(0)) dut_fall (
        .clk(clk), .rst(rst), .cpu_en(cpu_en), .cpu_re(cpu_re), .cpu_addr(cpu_addr),
        .cpu_wstrb(cpu_wstrb), .cpu_wdata(cpu_wdata), .cpu_rdata(fall_data),
        .clk_pixel(clk_pixel), .rst_pixel(rst_pixel), .x(x), .y(y), .visible(visible), .pixel(fall_pixel));
    vga_fb #(.CPU_READ_POSEDGE(1)) dut_rise (
        .clk(clk), .rst(rst), .cpu_en(cpu_en), .cpu_re(cpu_re), .cpu_addr(cpu_addr),
        .cpu_wstrb(cpu_wstrb), .cpu_wdata(cpu_wdata), .cpu_rdata(rise_data),
        .clk_pixel(clk_pixel), .rst_pixel(rst_pixel), .x(x), .y(y), .visible(visible), .pixel(rise_pixel));
    always #7 clk <= ~clk;
    always #20 clk_pixel <= ~clk_pixel;
    task automatic access(input int unsigned offset, input bit rd, input logic [3:0] mask,
                          input logic [31:0] value, input bit enabled = 1);
        logic [31:0] expected;
        expected = offset < 9600 ? model[offset/4] : 32'b0;
        @(posedge clk); #1;
        cpu_en = enabled; cpu_re = rd; cpu_addr = 14'(offset); cpu_wstrb = mask; cpu_wdata = value;
        @(posedge clk); #1;
        if (rd && enabled) begin
            assert (fall_data === expected && rise_data === expected)
                else $fatal(1, "framebuffer offset %0d expected %h fall %h rise %h", offset, expected, fall_data, rise_data);
            checks++;
        end
        if (enabled && offset < 9600)
            for (int b = 0; b < 4; b++) if (mask[b]) model[offset/4][b*8 +: 8] = value[b*8 +: 8];
        cpu_en = 0; cpu_re = 0; cpu_wstrb = 0;
    endtask
    task automatic sample(input int px, py, input bit active, input logic [3:0] expected);
        @(negedge clk_pixel); x = 10'(px); y = 10'(py); visible = active;
        repeat (3) @(posedge clk_pixel); #1;
        assert (fall_pixel === expected && rise_pixel === expected)
            else $fatal(1, "FB pixel %0d,%0d expected %h fall %h rise %h", px, py, expected, fall_pixel, rise_pixel);
        checks++;
    endtask
    initial begin
        for (int i = 0; i < 2400; i++) model[i] = 0;
        repeat (4) @(negedge clk); rst = 0;
        @(negedge clk_pixel); rst_pixel = 0;
        access(0, 1, 0, 0); access(9596, 1, 0, 0);
        for (int mask = 0; mask < 16; mask++) begin
            access(0, 1, 4'(mask), 32'h7654_3210);
            access(0, 1, 0, 0);
        end
        access(0, 0, 15, '1, 0); access(0, 1, 0, 0);
        access(9600, 0, 15, '1); access(16380, 0, 15, '1);
        access(9600, 1, 0, 0); access(16380, 1, 0, 0); access(0, 1, 0, 0);
        for (int word = 0; word < 2400; word++) begin
            logic [31:0] value;
            for (int n = 0; n < 8; n++) value[n*4 +: 4] = 4'((word*8+n + word/20) % 16);
            access(word*4, 0, 15, value);
            access(word*4, 1, 0, 0);
        end
        // Every logical pixel, all four corners of its physical 4x4 block.
        for (int py = 0; py < 120; py++)
            for (int px = 0; px < 160; px++) begin
                logic [3:0] expected;
                expected = model[py*20+px/8][(px%8)*4 +: 4];
                sample(px*4, py*4, 1, expected);
                sample(px*4+3, py*4, 1, expected);
                sample(px*4, py*4+3, 1, expected);
                sample(px*4+3, py*4+3, 1, expected);
            end
        sample(799, 524, 0, 0);
        @(negedge clk); rst = 1;
        repeat (2) @(negedge clk); rst = 0;
        access(0, 1, 0, 0); access(9596, 1, 0, 0);
        $display("PASS: framebuffer both CPU edges, all 2400 words, masks/read-first/readback, bounds, all 19200 logical pixels at four scaled corners and reset retention (%0d checks)", checks);
        $finish;
    end
    initial begin #15000000; $fatal(1, "TIMEOUT: VGA framebuffer"); end
endmodule
