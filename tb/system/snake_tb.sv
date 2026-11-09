`timescale 1ns/1ps
module snake_tb #(
    parameter bit PIPELINE = 0,
    parameter int CPU_HZ = 25000000
);
`include "tb/system/demo_board.svh"
    logic [7:0] font_reference [4096];
    // Simple deque oracle uses linear cells, not the program's ring/bit packing.
    int body[$];
    int food, score = 0, ticks = 0, status = 0;
    logic [31:0] random_state = 2377, start_cycles, first_interval;
    function automatic logic [31:0] random_next(input logic [31:0] state);
        logic [31:0] value;
        value = state ^ (state << 13); value ^= value >> 17; return value ^ (value << 5);
    endfunction
    function automatic bit occupied(input int position);
        bit found = 0;
        // Explicit addition avoids a Verilator 5.020 increment-hoisting bug
        // when an inlined early-return/foreach function is a while condition.
        for (int i = 0; i < body.size(); i = i+1) found |= body[i] == position;
        return found;
    endfunction
    task automatic new_food;
        bit found = 0;
        random_state = random_next(random_state);
        food = int'(random_state % 1040);
        for (int attempts = 0; attempts < 1040; attempts = attempts+1) begin
            if (!occupied(food)) begin found = 1; break; end
            food = (food+1)%1040;
        end
        assert (found) else $fatal(1,"reference food search exhausted");
    endtask
    task automatic initialize_model;
        body.delete(); body.push_back(13*40+18); body.push_back(13*40+19); body.push_back(13*40+20);
        random_state = 2377; score = 0; ticks = 0; status = 0; new_food();
        assert (food == 13*40+21) else $fatal(1,"training seed oracle");
    endtask
    task automatic advance(input int dx,dy);
        int head, x, y, next_position;
        head = body[body.size()-1]; x = head%40+dx; y = head/40+dy; ticks++;
        if (x < 0 || x >= 40 || y < 0 || y >= 26) begin status = 1; return; end
        next_position = y*40+x;
        if (next_position != food) void'(body.pop_front());
        else score++;
        assert (!occupied(next_position)) else $fatal(1,"reference script self-collision");
        body.push_back(next_position);
        if (next_position == food) new_food();
    endtask
    task automatic square(input int position,input logic [3:0] color);
        for (int y = 0; y < 3; ++y) for (int x = 0; x < 3; ++x)
            expected_pixels[16+(position/40)*4+y][(position%40)*4+x] = color;
    endtask
    task automatic text_row(input int row,input string text,input logic [3:0] color);
        logic [7:0] glyph;
        int code;
        for (int col = 0; col < 20; ++col) begin
            code = col < text.len() ? int'(text[col]) : 32;
            for (int y = 0; y < 8; ++y) begin
                glyph = font_reference[code*16+y*2];
                for (int x = 0; x < 8; ++x) expected_pixels[row*8+y][col*8+x] = glyph[7-x] ? color : 0;
            end
        end
    endtask
    task automatic image(input bit paused);
        foreach (expected_pixels[y,x]) expected_pixels[y][x] = 0;
        foreach (body[i]) square(body[i],i == body.size()-1 ? 4'he : 4'ha);
        square(food,4'hc);
        text_row(0,$sformatf("SCORE %04d",score),4'hf);
        text_row(1,status != 0 ? "GAME OVER: UP" : paused ? "PAUSED SW0" : "PLAY U L R D",status != 0 ? 4'hc : 4'hf);
    endtask
    task automatic await_tick(input int value);
        int waited = 0;
        while (led[7:0] != 8'(value) || !led[9]) begin
            @(negedge dut.clk_cpu);
            waited++;
            if (waited > CPU_HZ/3) $fatal(1,"Snake tick %0d not published (led=%h)",value,led);
        end
        repeat (100) @(negedge dut.clk_cpu);
        assert (!led[10] && dut.display_value == 16'(score)) else $fatal(1,"Snake blank budget/score");
        assert (led[15] == (status == 1)) else $fatal(1,"Snake terminal state");
    endtask
    task automatic manual_step(input int dx,dy);
        @(negedge dut.clk_cpu); sw[14] = 0;
        repeat (2000) @(negedge dut.clk_cpu);
        sw[14] = 1; advance(dx,dy); await_tick(ticks);
        sw[14] = 0; repeat (2000) @(negedge dut.clk_cpu);
    endtask
    initial begin
        $readmemh("rtl/mem/font_rom.mem",font_reference);
        sw = 16'h1000; initialize_model();
        wait (led == 16'h1200); start_cycles = dut.cycles;
        image(0); capture_frame("snake-start");
        // First move is driven by the real 125 ms timer, not a simulation knob.
        advance(1,0); await_tick(1); first_interval = dut.cycles-start_cycles;
        assert (first_interval >= 32'(CPU_HZ/8) && first_interval < 32'(CPU_HZ/6))
            else $fatal(1,"Snake eighth-second cadence=%0d",first_interval);
        sw[15] = 1; image(0); capture_frame("snake-score-1");
        // Only the first new direction may be queued before a tick.
        tap_button(5'b00010); tap_button(5'b00100); manual_step(0,-1);
        image(0); capture_frame("snake-turn");
        tap_button(5'b10000); // Down would reverse Up; it must be ignored.
        manual_step(0,-1);
        sw[0] = 1; wait (led[13]);
        image(1); capture_frame("snake-paused");
        sw[14] = 1; repeat (CPU_HZ/50) @(negedge dut.clk_cpu);
        assert (led[7:0] == 3) else $fatal(1,"paused Snake advanced");
        sw[14] = 0; sw[0] = 0; wait (!led[13]);
        repeat (12) manual_step(0,-1); // Eleven valid moves, then the top wall.
        assert (status == 1 && ticks == 15) else $fatal(1,"Snake wall script");
        image(0); capture_frame("snake-game-over");
        repeat (CPU_HZ/50) @(negedge dut.clk_cpu);
        assert (led[7:0] == 15) else $fatal(1,"dead Snake advanced");
        initialize_model(); tap_button(5'b00010); await_tick(0);
        image(0); capture_frame("snake-restarted");
        $display("PASS: Snake PIPELINE=%0d CPU_HZ=%0d actual C, 125ms cadence=%0d, food/growth/score, queued-turn/reversal, pause, wall/game-over/restart and %0d physical pixels",PIPELINE,CPU_HZ,first_interval,total_pixels);
        $finish;
    end
    initial begin #1400000000; $fatal(1,"TIMEOUT: Snake board program"); end
endmodule
