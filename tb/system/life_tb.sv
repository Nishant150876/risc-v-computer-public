`timescale 1ns/1ps
module life_tb #(
    parameter bit PIPELINE = 0,
    parameter int CPU_HZ = 25000000
);
`include "tb/system/demo_board.svh"
    bit cells [120][160], next_cells [120][160];
    logic [31:0] start_cycles, auto_interval;
    int generation = 0;
    int store_count = 0;
    logic [31:0] first_store = 0, render_cycles = 0, max_render_cycles = 0;
    initial forever begin
        @(posedge dut.clk_cpu);
        if (!dut.rst && dut.u_soc.vga_en && (|dut.u_soc.vga_wstrb) && dut.u_soc.vga_addr[31:16] == 16'h8002) begin
            if (store_count == 0) first_store = dut.cycles;
            store_count++;
            if (store_count == 2400) begin
                render_cycles = dut.cycles-first_store+1;
                if (render_cycles > max_render_cycles) max_render_cycles = render_cycles;
                store_count = 0;
            end
        end
    end
    task automatic seed_glider;
        foreach (cells[y,x]) cells[y][x] = 0;
        cells[16][17] = 1; cells[17][18] = 1;
        cells[18][16] = 1; cells[18][17] = 1; cells[18][18] = 1;
    endtask
    task automatic seed_gun;
        // Independent canonical RLE; not the C engine's coordinate table.
        string rle = "24bo$22bobo$12b2o6b2o12b2o$11bo3bo4b2o12b2o$2o8bo5bo3b2o$2o8bo3bob2o4bobo$10bo5bo7bo$11bo3bo$12b2o!";
        int count, x, y, live;
        foreach (cells[row,col]) cells[row][col] = 0;
        count = 0; x = 8; y = 8; live = 0;
        for (int i = 0; i < rle.len(); ++i) begin
            if (rle[i] >= "0" && rle[i] <= "9") count = count*10+int'(rle[i])-48;
            else begin
                if (count == 0) count = 1;
                case (rle[i])
                    "b": x += count;
                    "o": repeat (count) begin cells[y][x] = 1; x++; live++; end
                    "$": begin y += count; x = 8; end
                    default: begin end
                endcase
                count = 0;
            end
        end
        assert (live == 36) else $fatal(1,"bad reference gun RLE");
    endtask
    task automatic evolve;
        int neighbors;
        for (int y = 0; y < 120; ++y) for (int x = 0; x < 160; ++x) begin
            neighbors = 0;
            for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx)
                if ((dx != 0 || dy != 0) && x+dx >= 0 && x+dx < 160 && y+dy >= 0 && y+dy < 120)
                    neighbors += int'(cells[y+dy][x+dx]);
            next_cells[y][x] = neighbors == 3 || (neighbors == 2 && cells[y][x]);
        end
        foreach (cells[y,x]) cells[y][x] = next_cells[y][x];
        generation++;
    endtask
    task automatic image;
        foreach (cells[y,x]) expected_pixels[y][x] = cells[y][x] ? 4'ha : 0;
    endtask
    task automatic await_generation(input int value);
        int timeout_cycles = 0;
        while (dut.display_value != 16'(value) || led[14:8] != 7'h71) begin
            @(negedge dut.clk_cpu);
            timeout_cycles++;
            if (timeout_cycles > CPU_HZ/2) $fatal(1,"Life generation %0d not published, got %h",value,dut.display_value);
        end
        // HEX is written just before LED; let both writes retire.
        repeat (100) @(negedge dut.clk_cpu);
        assert (!led[15] && led[7:4] == 0) else $fatal(1,"Life rendering exceeded vertical blank or bad LED signature");
    endtask
    initial begin
        sw = 16'h8001; seed_glider(); image();
        wait (led[14:8] == 7'h71); await_generation(0);
        capture_frame("life-glider-0");
        for (int n = 1; n <= 4; ++n) begin
            tap_button(5'b01000); evolve(); await_generation(n);
        end
        image(); capture_frame("life-glider-4");
        assert (cells[17][18] && cells[19][19] && !cells[16][17]) else $fatal(1,"glider displacement oracle");
        // Held level must not create another generation.
        @(negedge dut.clk_cpu); btnR = 1;
        evolve(); await_generation(5);
        repeat (CPU_HZ/50) @(negedge dut.clk_cpu);
        assert (dut.display_value == 5) else $fatal(1,"held button repeated");
        btnR = 0; repeat (2000) @(negedge dut.clk_cpu);
        // Real elapsed-cycle pacing, with no shortened program timer.
        start_cycles = dut.cycles; sw = 1;
        await_generation(6); auto_interval = dut.cycles-start_cycles;
        assert (auto_interval >= 32'(CPU_HZ/4) && auto_interval < 32'(CPU_HZ/3))
            else $fatal(1,"Life quarter-second cadence %0d cycles",auto_interval);
        sw = 16'h8002; seed_gun(); generation = 0; image();
        tap_button(5'b00010); wait (led[3:0] == 2); await_generation(0);
        assert (led[3:0] == 2) else $fatal(1,"gun selection");
        capture_frame("life-gun-0");
        sw = 16'h8004;
        foreach (cells[y,x]) cells[y][x] = 0;
        cells[59][80] = 1; cells[59][81] = 1; cells[60][79] = 1; cells[60][80] = 1; cells[61][80] = 1;
        image(); tap_button(5'b00010); wait (led[3:0] == 4); await_generation(0);
        assert (led[3:0] == 4) else $fatal(1,"R-pentomino selection");
        capture_frame("life-rpentomino-0");
        // Necessary for tear-free redraws, and independent of the program's own
        // overrun flag: 45 blank lines x 800 pixel clocks at 25 MHz = 1.44 ms.
        assert (max_render_cycles > 0 && 64'(max_render_cycles) < 64'(CPU_HZ)*36000/25000000)
            else $fatal(1,"Life redraw span %0d cycles exceeds vertical blank",max_render_cycles);
        $display("PASS: Life PIPELINE=%0d CPU_HZ=%0d actual C, glider x4, gun RLE, R-pentomino, held/restart buttons, quarter-second cadence=%0d, max render=%0d cycles and %0d physical pixels",PIPELINE,CPU_HZ,auto_interval,max_render_cycles,total_pixels);
        $finish;
    end
    initial begin #800000000; $fatal(1,"TIMEOUT: Life board program"); end
endmodule
