// Included inside each Phase 7 game bench. The expected image is written only
// by that bench's independent model, never read from the DUT framebuffer.
    logic clk = 0, btnC = 0, btnU = 0, btnL = 0, btnR = 0, btnD = 0, RsRx = 1;
    logic [15:0] sw = 0, led;
    logic RsTx, dp, Hsync, Vsync;
    logic [6:0] seg;
    logic [3:0] an, vgaRed, vgaGreen, vgaBlue;
    logic unused_board_pins;
    assign unused_board_pins = ^{RsTx,dp,seg,an};
    string program_file, frame_directory;
    logic [3:0] expected_pixels [120][160];
    int x_pipe [4], y_pipe [4];
    int frame_file = 0, checked_pixels = 0, total_pixels = 0;
    bit checking = 0;
    basys3_soc #(.PIPELINE(PIPELINE), .CPU_HZ(CPU_HZ), .DEBOUNCE_CYCLES(3)) dut (.*);
    always #5 clk <= ~clk;
    always @(led)
        if ($test$plusargs("trace")) begin
            $display("TRACE: time=%0t cycles=%0d led=%h hex=%h",$time,dut.cycles,led,dut.display_value);
            $fflush();
        end
    always @(posedge dut.clk_cpu)
        if (!dut.rst && dut.halted) $fatal(1,"game CPU stopped, cause=%0d",dut.stop_cause);
    initial if ($test$plusargs("heartbeat")) forever begin
        #10000000;
        $display("HEARTBEAT: cycles=%0d pc=%h led=%h mode=%0d pending=%0d sw=%h",dut.cycles,
                 dut.u_soc.g_cpu.u_cpu.pc,led,dut.u_soc.u_vga.applied_mode,dut.u_soc.u_vga.pending,sw);
        $fflush();
    end

    function automatic logic [11:0] expected_rgb(input int x,y);
        logic [11:0] palette [16] = '{12'h000,12'h00a,12'h0a0,12'h0aa,
            12'ha00,12'ha0a,12'ha50,12'haaa,12'h555,12'h55f,12'h5f5,12'h5ff,
            12'hf55,12'hf5f,12'hff5,12'hfff};
        return (x < 640 && y < 480) ? palette[expected_pixels[y/4][x/4]] : 12'h000;
    endfunction
    initial forever begin
        @(posedge dut.clk_pixel);
        for (int i = 3; i > 0; --i) begin x_pipe[i] = x_pipe[i-1]; y_pipe[i] = y_pipe[i-1]; end
        x_pipe[0] = int'(dut.u_soc.u_vga.x); y_pipe[0] = int'(dut.u_soc.u_vga.y);
        #1;
        if (checking) begin
            assert (Hsync == !(x_pipe[3] >= 656 && x_pipe[3] < 752) &&
                    Vsync == !(y_pipe[3] >= 490 && y_pipe[3] < 492)) else $fatal(1,"demo VGA sync");
            assert ({vgaRed,vgaGreen,vgaBlue} === expected_rgb(x_pipe[3],y_pipe[3]))
                else $fatal(1,"demo pixel %0d,%0d actual=%h expected=%h",x_pipe[3],y_pipe[3],
                            {vgaRed,vgaGreen,vgaBlue},expected_rgb(x_pipe[3],y_pipe[3]));
            if (x_pipe[3] < 640 && y_pipe[3] < 480) begin
                if (frame_file != 0) $fwrite(frame_file,"%c%c%c",{vgaRed,vgaRed},{vgaGreen,vgaGreen},{vgaBlue,vgaBlue});
                checked_pixels++; total_pixels++;
            end
        end
    end
    task automatic capture_frame(input string name);
        if ($test$plusargs("trace")) begin $display("TRACE: checking frame %s",name); $fflush(); end
        wait (dut.u_soc.u_vga.applied_mode == 1 && !dut.u_soc.u_vga.pending);
        @(negedge Vsync); @(posedge Vsync);
        checked_pixels = 0;
        if (frame_directory != "") begin
            frame_file = $fopen($sformatf("%s/%s.ppm",frame_directory,name),"wb");
            assert (frame_file != 0) else $fatal(1,"cannot create frame %s",name);
            $fwrite(frame_file,"P6\n640 480\n255\n");
        end
        checking = 1;
        wait (checked_pixels == 307200);
        @(negedge dut.clk_pixel); checking = 0;
        if (frame_file != 0) begin $fclose(frame_file); frame_file = 0; end
    endtask
    task automatic tap_button(input logic [4:0] mask);
        assert (!mask[0]) else $fatal(1,"center is CPU reset, not a game input");
        @(negedge dut.clk_cpu); {btnD,btnR,btnL,btnU,btnC} = mask;
        repeat (2000) @(negedge dut.clk_cpu);
        {btnD,btnR,btnL,btnU,btnC} = 0;
        repeat (2000) @(negedge dut.clk_cpu);
    endtask
    initial begin
        void'($value$plusargs("frames=%s",frame_directory));
        if (!$value$plusargs("program=%s",program_file)) $fatal(1,"game bench requires +program=<image.mem>");
        for (int i = 0; i < 16384; ++i) dut.u_soc.u_ram.mem[i] = 32'ha5a5a5a5;
        $readmemh(program_file,dut.u_soc.u_ram.mem);
    end
