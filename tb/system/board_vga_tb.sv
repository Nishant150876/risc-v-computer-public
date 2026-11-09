`timescale 1ns/1ps
// Run the actual compiled vga_demo on the full board top. Switch from text
// to pixels to bars; compare every active output pixel against expected
// program content, not the DUT's character/framebuffer storage.
module board_vga_tb #(
    parameter bit PIPELINE = 0,
    parameter int CPU_HZ = 25000000
);
    logic clk = 0, btnC = 0, btnU = 0, btnL = 0, btnR = 0, btnD = 0, RsRx = 1;
    logic [15:0] sw = 0, led;
    logic RsTx, dp;
    logic [6:0] seg;
    logic [3:0] an, vgaRed, vgaGreen, vgaBlue;
    logic Hsync, Vsync;
    logic unused_board_pins;
    assign unused_board_pins = ^{RsTx,dp,seg,an};
    string program_file, frame_directory;
    int frame_file = 0;
    string text_lines [30];
    logic [7:0] font_reference [4096];
    int check_mode = -1, checked_pixels = 0, total_pixels = 0, cpu_ticks = 0;
    int x_pipe [4], y_pipe [4];
    basys3_soc #(.PIPELINE(PIPELINE), .CPU_HZ(CPU_HZ), .DEBOUNCE_CYCLES(3)) dut (.*);
    always #5 clk <= ~clk;
    always @(posedge dut.clk_cpu) begin
        if (!dut.rst && dut.halted) $fatal(1, "VGA C demo stopped with cause %0d", dut.stop_cause);
    end
    function automatic logic [11:0] expected_color(input int px, py, mode);
        int lx, ly, column, code;
        logic [3:0] index;
        logic [4:0] row;
        logic [7:0] glyph_row;
        logic [11:0] colors [16] = '{12'h000,12'h00a,12'h0a0,12'h0aa,
            12'ha00,12'ha0a,12'ha50,12'haaa,12'h555,12'h55f,12'h5f5,12'h5ff,
            12'hf55,12'hf5f,12'hff5,12'hfff};
        logic [11:0] bars_rgb [8] = '{12'hfff,12'hff0,12'h0ff,12'h0f0,12'hf0f,12'hf00,12'h00f,12'h000};
        if (px >= 640 || py >= 480) return 0;
        if (mode == 0) begin
            column = px/8; row = 5'(py/16);
            code = column < text_lines[row].len() ? int'(text_lines[row].getc(column)) : 32;
            glyph_row = font_reference[code*16+py%16];
            return glyph_row[7-px%8] ? 12'hfff : 12'h000;
        end
        if (mode == 2) return bars_rgb[px/80];
        lx = px/4; ly = py/4;
        index = 4'(((lx/16)+(ly/16))%16);
        if (lx == 0 && ly == 0) index = 4;
        if (lx == 159 && ly == 0) index = 2;
        if (lx == 0 && ly == 119) index = 1;
        if (lx == 159 && ly == 119) index = 15;
        return colors[index];
    endfunction
    initial forever begin
        @(posedge dut.clk_pixel);
        for (int i = 3; i > 0; i--) begin x_pipe[i] = x_pipe[i-1]; y_pipe[i] = y_pipe[i-1]; end
        x_pipe[0] = int'(dut.u_soc.u_vga.x); y_pipe[0] = int'(dut.u_soc.u_vga.y);
        #1;
        if (check_mode >= 0) begin
            assert (Hsync == !(x_pipe[3] >= 656 && x_pipe[3] < 752) &&
                    Vsync == !(y_pipe[3] >= 490 && y_pipe[3] < 492))
                else $fatal(1, "C board VGA sync alignment");
            assert ({vgaRed,vgaGreen,vgaBlue} === expected_color(x_pipe[3],y_pipe[3],check_mode))
                else $fatal(1, "C board pixel %0d,%0d mode %0d got %h expected %h", x_pipe[3],y_pipe[3],check_mode,
                            {vgaRed,vgaGreen,vgaBlue},expected_color(x_pipe[3],y_pipe[3],check_mode));
            if (x_pipe[3] < 640 && y_pipe[3] < 480) begin
                if (frame_file != 0)
                    $fwrite(frame_file, "%c%c%c", {vgaRed,vgaRed}, {vgaGreen,vgaGreen}, {vgaBlue,vgaBlue});
                checked_pixels++; total_pixels++;
            end
        end
    end
    task automatic await_mode(input int mode);
        int waited;
        waited = 0;
        check_mode = -1;
        while (dut.u_soc.u_vga.applied_mode != 2'(mode) || dut.u_soc.u_vga.pending) begin
            @(negedge dut.clk_cpu);
            waited = waited + 1;
            if (waited > CPU_HZ/20) $fatal(1, "C did not select mode %0d", mode);
        end
        // A fresh vsync ensures the checked area is one complete later frame.
        @(negedge Vsync); @(posedge Vsync);
        checked_pixels = 0;
        if (frame_directory != "") begin
            frame_file = $fopen($sformatf("%s/mode%0d.ppm",frame_directory,mode), "wb");
            assert (frame_file != 0) else $fatal(1, "cannot create VGA frame in %s", frame_directory);
            $fwrite(frame_file,"P6\n640 480\n255\n");
        end
        check_mode = mode;
        wait (checked_pixels >= 307200);
        @(negedge dut.clk_pixel); check_mode = -1;
        if (frame_file != 0) begin $fclose(frame_file); frame_file = 0; end
        assert (led == 16'h6006 && dut.display_value == 16'h6404)
            else $fatal(1, "VGA ready signature changed");
    endtask
    initial begin
        for (int i = 0; i < 30; i++) text_lines[i] = "";
        text_lines[0] = "hello, world";
        text_lines[2] = "RISC-V Computer / Basys 3";
        text_lines[3] = "80 x 30 text / 8 x 16 public-domain font";
        text_lines[4] = "160 x 120 pixels / 16 colors / 4 x 4 scaling";
        text_lines[6] = "RV32I: ready  -42  640  0x480  V  %";
        text_lines[7] = "SW0: pixels   SW1: color bars   both off: alternate";
        text_lines[8] = $sformatf("CPU clock: %0d Hz (configured, not measured Fmax)", CPU_HZ);
        $readmemh("rtl/mem/font_rom.mem", font_reference);
        void'($value$plusargs("frames=%s", frame_directory));
        if (!$value$plusargs("program=%s", program_file)) $fatal(1, "board_vga_tb needs +program=<file.mem>");
        for (int i = 0; i < 16384; i++) dut.u_soc.u_ram.mem[i] = 32'ha5a5a5a5;
        $readmemh(program_file, dut.u_soc.u_ram.mem);
        wait (dut.locked);
        cpu_ticks = 0;
        while (led != 16'h6006) begin
            @(negedge dut.clk_cpu);
            cpu_ticks = cpu_ticks + 1;
            if (cpu_ticks > CPU_HZ/5) $fatal(1, "VGA C program never became ready");
        end
        await_mode(0);
        @(negedge clk); sw = 1;
        await_mode(1);
        @(negedge clk); sw = 2;
        await_mode(2);
        assert (total_pixels >= 3*307200) else $fatal(1, "VGA board coverage");
        $display("PASS: real RV32I VGA demo PIPELINE=%0d, full-board clocks/bus/C, exact text plus all scaled framebuffer pixels and color bars on physical output ports (%0d visible pixels); monitor not tested", PIPELINE,total_pixels);
        $finish;
    end
    initial begin #250000000; $fatal(1, "TIMEOUT: full-board VGA demo"); end
endmodule
