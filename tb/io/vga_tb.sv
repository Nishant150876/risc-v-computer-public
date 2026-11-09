`timescale 1ns/1ps
// The real bus and VGA together, with unrelated CPU/pixel clocks. Reused by
// vga_pipe_tb for rising-edge pipeline loads; default is single-cycle timing.
module vga_tb #(parameter bit READ_POSEDGE = 0);
    logic clk = 0, clk_pixel = 0, rst = 1, rst_pixel = 1, cpu_rst = 1;
    logic re = 0;
    logic [3:0] wstrb = 0;
    logic [31:0] addr = 0, wdata = 0, rdata;
    logic vga_en, vga_re;
    logic [3:0] vga_wstrb;
    logic [31:0] vga_addr, vga_wdata, vga_regs_rdata, vga_mem_rdata;
    logic [3:0] red, green, blue;
    logic hsync, vsync;
    logic mapped, unused_ram_en, unused_io_en, unused_uart_en, unused_uart_re;
    logic [3:0] unused_ram_wstrb, unused_io_wstrb, unused_uart_wstrb;
    logic [1:0] unused_io_reg, unused_uart_reg;
    logic [31:0] unused_ram_addr, unused_ram_wdata, unused_io_wdata, unused_uart_wdata;
    logic [31:0] chars [600], pixels [2400];
    int requested = 2, model_mode = 2;
    bit mode_pending = 0;
    int rx = 0, ry = 0, frames = 0, scanned = 0, checks = 0, warm = 0;
    logic [11:0] rgb_expect [4];
    logic hs_expect [4], vs_expect [4];
    // Raw coordinates delayed to the pins, and when the pins entered/left
    // vertical blank. STATUS bit 0 must follow the pins, not raw timing.
    int x_disp [4], y_disp [4];
    time blank_on_pins = 0, active_on_pins = 0;

    bus #(.READ_POSEDGE(READ_POSEDGE)) u_bus (
        .clk(clk), .rst(cpu_rst), .re(re), .wstrb(wstrb), .addr(addr), .wdata(wdata),
        .rdata(rdata), .mapped(mapped), .ram_en(unused_ram_en), .ram_wstrb(unused_ram_wstrb),
        .ram_addr(unused_ram_addr), .ram_wdata(unused_ram_wdata), .ram_rdata(32'h12345678),
        .io_en(unused_io_en), .io_reg(unused_io_reg), .io_wstrb(unused_io_wstrb),
        .io_wdata(unused_io_wdata), .io_rdata(32'h87654321),
        .uart_en(unused_uart_en), .uart_re(unused_uart_re), .uart_reg(unused_uart_reg),
        .uart_wstrb(unused_uart_wstrb), .uart_wdata(unused_uart_wdata), .uart_rdata(32'h5a),
        .cycles(32'h55aa55aa), .instret(32'haa55aa55),
        .vga_en(vga_en), .vga_re(vga_re), .vga_wstrb(vga_wstrb),
        .vga_addr(vga_addr), .vga_wdata(vga_wdata),
        .vga_regs_rdata(vga_regs_rdata), .vga_mem_rdata(vga_mem_rdata));
    vga #(.CPU_READ_POSEDGE(READ_POSEDGE)) dut (
        .clk(clk), .rst(rst), .clk_pixel(clk_pixel), .rst_pixel(rst_pixel),
        .en(vga_en), .re(vga_re), .wstrb(vga_wstrb), .addr(vga_addr), .wdata(vga_wdata),
        .regs_rdata(vga_regs_rdata), .mem_rdata(vga_mem_rdata),
        .red(red), .green(green), .blue(blue), .hsync(hsync), .vsync(vsync));
    always #7 clk <= ~clk;
    always #20 clk_pixel <= ~clk_pixel;

    // Literal VGA palette, independent of the DUT function.
    function automatic logic [11:0] color(input logic [3:0] index);
        logic [11:0] table_rgb [16] = '{12'h000,12'h00a,12'h0a0,12'h0aa,
            12'ha00,12'ha0a,12'ha50,12'haaa,12'h555,12'h55f,12'h5f5,12'h5ff,
            12'hf55,12'hf5f,12'hff5,12'hfff};
        return table_rgb[index];
    endfunction
    function automatic logic text_dot(input int px, py);
        int cell_number, code;
        logic [7:0] rows [8];
        cell_number = (py/16)*80+px/8;
        code = int'(chars[cell_number/4][(cell_number%4)*8 +: 8]);
        case (code)
            65: rows = '{8'h0c,8'h1e,8'h33,8'h33,8'h3f,8'h33,8'h33,8'h00};
            70: rows = '{8'h7f,8'h46,8'h16,8'h1e,8'h16,8'h06,8'h0f,8'h00};
            default: rows = '{default:8'h00};
        endcase
        return rows[(py%16)/2][px%8];
    endfunction
    function automatic logic [11:0] expected_rgb(input int px, py);
        int position;
        logic [11:0] bar_colors [8] = '{12'hfff,12'hff0,12'h0ff,12'h0f0,
                                                       12'hf0f,12'hf00,12'h00f,12'h000};
        if (px >= 640 || py >= 480) return 0;
        case (model_mode)
            0: return text_dot(px, py) ? 12'hfff : 12'h000;
            1: begin
                position = (py/4)*160+px/4;
                return color(pixels[position/8][(position%8)*4 +: 4]);
            end
            2: return bar_colors[px/80];
            default: return 0;
        endcase
    endfunction
    // Check every output pixel and both syncs, including porches, as scanout
    // crosses modes. Four pipeline edges, not a screenshot of a single pixel.
    initial forever begin
        @(posedge clk_pixel);
        if (rst_pixel) begin
            rx = 0; ry = 0; warm = 0; model_mode = 2; frames = 0;
            for (int i = 0; i < 4; i++) begin rgb_expect[i] = 0; hs_expect[i] = 1; vs_expect[i] = 1; end
        end else begin
            assert (dut.x == 10'(rx) && dut.y == 10'(ry)) else $fatal(1, "VGA scan reference drift");
            for (int i = 3; i > 0; i--) begin
                rgb_expect[i] = rgb_expect[i-1];
                hs_expect[i] = hs_expect[i-1]; vs_expect[i] = vs_expect[i-1];
            end
            rgb_expect[0] = expected_rgb(rx, ry);
            hs_expect[0] = !(rx >= 656 && rx < 752);
            vs_expect[0] = !(ry >= 490 && ry < 492);
            if (rx == 0 && ry == 480 && mode_pending) begin model_mode = requested; mode_pending = 0; end
            if (++rx == 800) begin rx = 0; if (++ry == 525) begin ry = 0; frames++; end end
            for (int i = 3; i > 0; i--) begin x_disp[i] = x_disp[i-1]; y_disp[i] = y_disp[i-1]; end
            x_disp[0] = int'(dut.x); y_disp[0] = int'(dut.y);
            warm++;
            if (warm >= 4 && x_disp[3] == 0 && y_disp[3] == 480) blank_on_pins = $time;
            if (warm >= 4 && x_disp[3] == 0 && y_disp[3] == 0) active_on_pins = $time;
            #1;
            if (warm >= 4) begin
                assert ({red,green,blue} === rgb_expect[3] && hsync === hs_expect[3] && vsync === vs_expect[3])
                    else $fatal(1, "VGA pin mismatch near %0d,%0d mode=%0d rgb=%h expected=%h hs/vs=%b%b expected=%b%b",
                                rx, ry, model_mode, {red,green,blue}, rgb_expect[3], hsync,vsync,hs_expect[3],vs_expect[3]);
                scanned++;
            end
        end
    end
    task automatic access(input logic [31:0] address, input bit rd, input logic [3:0] mask,
                          input logic [31:0] value, output logic [31:0] result);
        @(posedge clk); #1;
        addr = address; re = rd; wstrb = mask; wdata = value;
        @(posedge clk); #1;
        result = rdata;
        assert (!unused_ram_en && !unused_io_en && !unused_uart_en)
            else $fatal(1, "VGA MMIO aliased another peripheral at %h", address);
        if (cpu_rst) assert (!vga_en && vga_wstrb == 0) else $fatal(1, "reset leaked VGA side effect");
        if (!cpu_rst && mask != 0) begin
            if (address >= 32'h8001_0000 && address < 32'h8001_0960)
                for (int b = 0; b < 4; b++)
                    if (mask[b]) chars[(address-32'h8001_0000)/4][b*8 +: 8] = value[b*8 +: 8];
            if (address >= 32'h8002_0000 && address < 32'h8002_2580)
                for (int b = 0; b < 4; b++)
                    if (mask[b]) pixels[(address-32'h8002_0000)/4][b*8 +: 8] = value[b*8 +: 8];
            if ((address & 32'hffff_fffc) == 32'h8000_002c && mask[0] && !mode_pending) begin
                requested = int'(value[1:0]); mode_pending = 1;
            end
        end
        re = 0; wstrb = 0;
        checks++;
    endtask
    task automatic write_word(input logic [31:0] address, value, input logic [3:0] mask = 15);
        logic [31:0] unused_read;
        access(address, 0, mask, value, unused_read);
    endtask
    task automatic read_check(input logic [31:0] address, expected);
        logic [31:0] value;
        access(address, 1, 0, 0, value);
        assert (value === expected) else $fatal(1, "VGA read %h got %h expected %h", address, value, expected);
    endtask
    task automatic await_mode(input int expected);
        logic [31:0] status;
        do begin
            repeat (100) @(posedge clk);
            access(32'h8000_0028, 1, 0, 0, status);
        end while (status[1]);
        assert (status[3:2] == 2'(expected)) else $fatal(1, "mode acknowledgement %h", status);
        read_check(32'h8000_002c, 32'(expected));
    endtask
    task automatic poll_vblank_edge(input bit level);
        logic [31:0] status;
        time pins_changed, seen;
        wait (ry == (level ? 470 : 515));
        do access(32'h8000_0028, 1, 0, 0, status); while (status[0] != level);
        seen = $time;
        assert (status[31:1] == 31'h2) else $fatal(1, "STATUS %h while polling vblank (expected pixels mode, not pending)", status);
        pins_changed = level ? blank_on_pins : active_on_pins;
        assert (pins_changed != 0 && seen >= pins_changed && seen - pins_changed <= 6*14)
            else $fatal(1, "STATUS vblank=%0d seen at %0d ns, pins changed at %0d ns", level, seen, pins_changed);
    endtask
    task automatic full_frame;
        int target;
        target = frames + 2;
        wait (frames >= target);
    endtask
    initial begin
        for (int i = 0; i < 600; i++) chars[i] = 32'h20202020;
        for (int i = 0; i < 2400; i++) pixels[i] = 0;
        repeat (4) @(negedge clk); rst = 0; cpu_rst = 0;
        @(negedge clk_pixel); rst_pixel = 0;
        read_check(32'h8000_0028, 8); read_check(32'h8000_002c, 2);
        write_word(32'h8000_002c, 0, 2); read_check(32'h8000_002c, 2); // lane 0 only
        write_word(32'h8000_0028, '1); read_check(32'h8000_0028, 8); // status read-only
        for (int mask = 0; mask < 16; mask++) begin
            write_word(32'h8001_0000, 32'h4641_4641, 4'(mask));
            read_check(32'h8001_0000, chars[0]);
        end
        write_word(32'h8001_095c, 32'h4120_2020); read_check(32'h8001_095c, chars[599]);
        write_word(32'h8001_0960, '1); write_word(32'h8001_0ffc, '1);
        read_check(32'h8001_0960, 0); read_check(32'h8001_0ffc, 0); read_check(32'h8001_1000, 0);
        for (int word = 0; word < 2400; word++) begin
            logic [31:0] value;
            for (int n = 0; n < 8; n++) value[n*4 +: 4] = 4'((word*8+n+word/20)%16);
            write_word(32'h8002_0000+32'(word*4), value);
        end
        read_check(32'h8002_0000, pixels[0]); read_check(32'h8002_257c, pixels[2399]);
        write_word(32'h8002_2580, '1); write_word(32'h8002_3ffc, '1);
        read_check(32'h8002_2580, 0); read_check(32'h8002_3ffc, 0); read_check(32'h8002_4000, 0);
        full_frame(); // Includes a whole default color-bar frame.
        write_word(32'h8000_002c, 0);
        write_word(32'h8000_002c, 1); // pending request must not be replaced
        read_check(32'h8000_002c, 0);
        await_mode(0); full_frame();
        write_word(32'h8000_002c, 1); await_mode(1); full_frame();
        // CPU-only reset suppresses writes without resetting display state.
        @(negedge clk); cpu_rst = 1;
        write_word(32'h8002_0000, '1); write_word(32'h8000_002c, 0);
        @(negedge clk); cpu_rst = 0;
        read_check(32'h8002_0000, pixels[0]); read_check(32'h8000_002c, 1);
        wait (ry == 500); repeat (10) @(negedge clk);
        begin
            logic [31:0] status;
            access(32'h8000_0028, 1, 0, 0, status);
            assert (status == 5) else $fatal(1, "synchronized vblank/status %h", status);
        end
        wait (ry == 100); repeat (10) @(negedge clk);
        read_check(32'h8000_0028, 4);
        // Displayed-vblank latency: STATUS bit 0 may change only after the
        // pins change, then within two synchronizer flops plus one bus read.
        poll_vblank_edge(1); poll_vblank_edge(0);
        write_word(32'h8000_002c, 3); await_mode(3); full_frame();
        assert (scanned > 4*420000 && mapped) else $fatal(1, "VGA check coverage/mapping");
        // Abort a pending mode change with a global reset in mid-operation.
        // The next handshake must work, and configuration-time VRAM persists.
        write_word(32'h8000_002c, 0);
        @(negedge clk_pixel);
        rst = 1; rst_pixel = 1; cpu_rst = 1; mode_pending = 0; requested = 2;
        repeat (4) @(negedge clk_pixel);
        assert ({red,green,blue} == 0 && hsync && vsync)
            else $fatal(1, "global reset did not blank VGA pins");
        rst_pixel = 0;
        @(negedge clk); rst = 0; cpu_rst = 0;
        repeat (10) @(negedge clk);
        read_check(32'h8000_0028, 8); read_check(32'h8000_002c, 2);
        read_check(32'h8001_0000, chars[0]); read_check(32'h8002_257c, pixels[2399]);
        write_word(32'h8000_002c, 1); await_mode(1); full_frame();
        $display("PASS: VGA bus/pins READ_POSEDGE=%0d, all modes and pixels, frame-boundary CDC, ignored pending/lane writes, readback, boundaries, displayed-vblank status latency, CPU-reset isolation and pending/global-reset recovery (%0d accesses, %0d pixels)", READ_POSEDGE, checks, scanned);
        $finish;
    end
    initial begin #250000000; $fatal(1, "TIMEOUT: VGA integration"); end
endmodule
