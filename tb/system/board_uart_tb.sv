`timescale 1ns/1ps

// The unchanged hello ELF on the physical top: actual 25 MHz CPU clock,
// 217-clock serial bits, and the real 25,000,000-cycle counter interval.
// Independent pin decoder/stimulus; no UART RTL is used as the oracle.
module board_uart_tb #(
    parameter bit PIPELINE = 1'b0  // 1: run the same checks on cpu_pipe
);
    localparam time BIT_TIME = 217 * 40;
    logic clk = 0, btnC = 0, btnU = 0, btnL = 0, btnR = 0, btnD = 0, RsRx = 1;
    logic [15:0] sw = 0, led;
    logic RsTx, dp;
    logic [6:0] seg;
    logic [3:0] an;
    string program_file;
    byte unsigned observed[$];
    int cursor = 0;
    logic [31:0] first_counter_cycles, second_counter_cycles;
    logic [3:0] vgaRed, vgaGreen, vgaBlue;
    logic Hsync, Vsync;
    logic unused_vga_pins;
    assign unused_vga_pins = ^{vgaRed, vgaGreen, vgaBlue, Hsync, Vsync};

    basys3_soc #(.PIPELINE(PIPELINE), .DEBOUNCE_CYCLES(3)) dut (.*);
    always #5 clk <= ~clk;

    task automatic fail(input string message);
        $display("FAIL: board UART: %s (pc=%h, decoded=%0d)", message, dut.u_soc.g_cpu.u_cpu.pc, observed.size());
        $fatal(1, "%s", message);
    endtask
    initial forever begin
        logic [7:0] character;
        @(negedge RsTx); #(BIT_TIME / 2);
        if (RsTx) fail("false TX start");
        for (int bit_index = 0; bit_index < 8; bit_index++) begin #(BIT_TIME); character[bit_index] = RsTx; end
        #(BIT_TIME);
        if (!RsTx) fail("TX stop bit/framing");
        observed.push_back(character);
    end
    task automatic expect_text(input string expected);
        for (int i = 0; i < expected.len(); i++) begin
            wait (observed.size() > cursor);
            if (observed[cursor] !== expected[i])
                fail($sformatf("byte %0d expected %h, got %h", cursor, expected[i], observed[cursor]));
            cursor++;
        end
        if (dut.halted || !dp) fail("CPU stopped or unexpected decimal point");
    endtask
    task automatic type_text(input string text);
        for (int i = 0; i < text.len(); i++) begin
            #17; RsRx = 0; #(BIT_TIME);
            for (int b = 0; b < 8; b++) begin RsRx = text[i][b]; #(BIT_TIME); end
            RsRx = 1; #(BIT_TIME);
        end
    endtask

    initial begin
        if (!$value$plusargs("program=%s", program_file)) fail("needs +program=<file.mem>");
        for (int i = 0; i < 16384; i++) dut.u_soc.u_ram.mem[i] = 32'ha5a5_a5a5;
        $readmemh(program_file, dut.u_soc.u_ram.mem);
        expect_text("hello, world\r\n\r\ncounter: 0\r\n");
        first_counter_cycles = dut.cycles;
        fork
            type_text("RISC-V echo 0123456789 !?\r\n");
            expect_text("RISC-V echo 0123456789 !?\r\n");
        join
        // Paste while printf owns TX: the receive FIFO must retain these
        // bytes until the CPU finishes printing, then echo them in order.
        fork
            begin wait (led == 1); type_text("FIFO-16"); end
            expect_text("\r\ncounter: 1\r\n");
        join
        second_counter_cycles = dut.cycles;
        if (second_counter_cycles - first_counter_cycles < 24900000 ||
            second_counter_cycles - first_counter_cycles > 25100000)
            fail("live counter interval differs from one real second");
        expect_text("FIFO-16");
        if (led != 1 || dut.display_value != 1) fail("live counter board mirrors");
        if (dut.u_soc.u_uart.overrun || dut.u_soc.u_uart.frame_error) fail("UART error during valid traffic");

        // UART keeps receiving while only the CPU is reset. Its queued byte
        // must survive the restart and the new greeting/counter output.
        wait (!dut.u_soc.u_uart.tx_busy);
        @(negedge dut.clk_cpu); btnC = 1;
        repeat (8) @(posedge dut.clk_cpu); #1;
        if (!dut.u_soc.cpu_rst || dut.rst || !dut.locked) fail("CPU reset domains");
        type_text("R");
        repeat (4) @(posedge dut.clk_cpu); #1;
        if (dut.u_soc.u_uart.count != 1 || led != 1) fail("UART/IO state lost during CPU reset");
        @(negedge dut.clk_cpu); btnC = 0;
        expect_text("hello, world\r\n\r\ncounter: 0\r\nR");
        $display("PASS: %s full board UART: hello, real one-second counter, exact echo, concurrent FIFO paste and CPU-reset preservation (%0d decoded bytes)", program_file, cursor);
        $finish;
    end
    initial begin #(64'd3000000000); fail("timeout waiting for board console output"); end
    logic unused_display;
    assign unused_display = ^{seg, an};
endmodule
