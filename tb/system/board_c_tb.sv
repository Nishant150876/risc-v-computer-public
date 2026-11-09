`timescale 1ns/1ps

// Runs the compiled board C image on the complete physical top, basys3_soc:
// clock model, lock reset, soc fetch path, bus, board I/O and counters. It
// complements cpu_tb, which checks the same image instruction by instruction
// against a bench-assembled memory system.
//
// Plusargs:
//   +program=<file.mem>    the Fibonacci board image (required)
//   +max_cycles=<n>        CPU-clock limit for each wait (default 20000)
//
// The program never halts. Each step changes the switches while the CPU runs
// and waits for the LEDs, the hex register and the scanned seven-segment
// pins to show the expected value. Expected results are literal constants.
module board_c_tb #(
    parameter bit PIPELINE = 1'b0  // 1: run the same checks on cpu_pipe
);
    logic clk = 0, btnC = 0, btnU = 0, btnL = 0, btnR = 0, btnD = 0, RsRx = 1;
    logic [15:0] sw = 16'd20, led;
    logic RsTx, dp;
    logic [6:0] seg;
    logic [3:0] an;
    string program_file;
    int unsigned max_cycles = 20000;
    int steps = 0;

    logic [3:0] vgaRed, vgaGreen, vgaBlue;
    logic Hsync, Vsync;
    logic unused_vga_pins;
    assign unused_vga_pins = ^{vgaRed, vgaGreen, vgaBlue, Hsync, Vsync};

    basys3_soc #(.PIPELINE(PIPELINE), .DEBOUNCE_CYCLES(3)) dut (.*);
    always #5 clk <= ~clk;  // 100 MHz board oscillator

    task automatic fail(input string message);
        $display("FAIL: %s (sw=%h led=%h display=%h pc=%h)", message, sw, led,
                 dut.display_value, dut.u_soc.g_cpu.u_cpu.pc);
        $fatal(1, "%s", message);
    endtask

    // Active-low segments a..g on seg[0..6], from the segment letters lit.
    function automatic logic [6:0] glyph(input logic [3:0] n);
        string lit [16] = '{"abcdef", "bc", "abdeg", "abcdg", "bcfg", "acdfg", "acdefg", "abc",
                             "abcdefg", "abcdfg", "abcefg", "cdefg", "adef", "bcdeg", "adefg", "aefg"};
        logic [6:0] result = '1;
        string segments = lit[n];
        for (int segment = 0; segment < 7; segment++)
            for (int c = 0; c < segments.len(); c++)
                if (segments[c] == 8'(97 + segment)) result[segment] = 0;
        return result;
    endfunction

    task automatic await_outputs(input logic [15:0] leds, input logic [15:0] value);
        int unsigned waited = 0;
        while (!(led == leds && dut.display_value == value)) begin
            @(posedge dut.clk_cpu); #1;
            if (dut.halted) fail($sformatf("board program stopped, cause %0d", dut.stop_cause));
            if (++waited > max_cycles)
                fail($sformatf("outputs never reached LED=%h display=%h", leds, value));
        end
    endtask

    // Watch one full scan: every digit must be selected and show its nibble.
    task automatic check_pins(input logic [15:0] value);
        bit [3:0] seen = 0;
        int unsigned waited = 0;
        while (seen != 4'b1111) begin
            @(posedge dut.clk_cpu); #1;
            if (!dp || !RsTx) fail("decimal point lit or UART transmitter not idle");
            if ($countones(~an) != 1) fail($sformatf("anodes %b do not select one digit", an));
            for (int d = 0; d < 4; d++) begin
                if (!an[d]) begin
                    if (seg !== glyph(value[d*4 +: 4]))
                        fail($sformatf("digit %0d shows %b for value %h", d, seg, value));
                    seen[d] = 1;
                end
            end
            if (++waited > 4 * 6250 + 10) fail("display scan did not visit all four digits");
        end
    endtask

    task automatic step(input logic [15:0] switches, input logic [15:0] value);
        @(negedge dut.clk_cpu); sw = switches;
        await_outputs(switches, value);
        check_pins(value);
        steps++;
    endtask

    initial begin
        if (!$value$plusargs("program=%s", program_file)) begin
            $display("FAIL: board_c_tb needs +program=<file.mem>");
            $fatal(1, "missing +program");
        end
        void'($value$plusargs("max_cycles=%d", max_cycles));
        // Poison RAM first so the image cannot rely on unwritten words.
        for (int i = 0; i < 16384; i++) dut.u_soc.u_ram.mem[i] = 32'ha5a5_a5a5;
        $readmemh(program_file, dut.u_soc.u_ram.mem);

        wait (dut.locked);
        // The gate case, then live switch changes as an owner would make them.
        await_outputs(16'd20, 16'h1a6d);
        check_pins(16'h1a6d);
        steps++;
        step(16'd0, 16'h0000);
        step(16'd1, 16'h0001);
        step(16'd7, 16'h000d);
        step(16'd19, 16'h1055);
        step(16'd21, 16'hffff);   // out of range
        step(16'hffff, 16'hffff);
        step(16'd20, 16'h1a6d);

        // Centre button: the CPU restarts, peripherals keep their values.
        @(negedge dut.clk_cpu); btnC = 1; sw = 16'd5;
        repeat (8) @(posedge dut.clk_cpu); #1;
        if (!dut.u_soc.cpu_rst || dut.rst || !dut.locked || led != 16'd20 ||
            dut.display_value != 16'h1a6d || dut.instret != 0)
            fail("centre button did not hold only the CPU in reset");
        @(negedge dut.clk_cpu); btnC = 0;
        await_outputs(16'd5, 16'h0005);
        check_pins(16'h0005);
        steps++;
        if (dut.instret == 0 || dut.cycles < dut.instret)
            fail("performance counters did not run after the restart");

        $display("PASS: %s board top: gate 1A6D, then %0d live switch/restart steps with scanned pins",
                 program_file, steps - 1);
        $finish;
    end
endmodule
