`timescale 1ns/1ps

// Program runner for cpu_single. Loads a .mem image into RAM at address 0,
// runs until the CPU stops or a cycle limit, then checks the result.
//
// Plusargs:
//   +program=<file.mem>    image to load (required; one 32-bit word per line)
//   +max_cycles=<n>        timeout in cycles (default 200000)
//   +trace                 print every retired instruction
//   +vcd=<file.vcd>        dump waveforms for GTKWave
//   +expect=<file>         after the stop, check RAM words: "<addr> <value>" hex per line
//   +expect_stop=<CAUSE>   ECALL or EBREAK: require that stop as well as the pass word.
//                          ILLEGAL, MISALIGNED_FETCH, MISALIGNED_LOAD or
//                          MISALIGNED_STORE: expect that fault instead of a pass word.
//   +quiet                 do not print the register dump on success
//   +board_io              enable Phase 3 MMIO (requires both expected outputs)
//   +switches=<hex>        simulated switch inputs (default 0)
//   +expect_leds=<hex>     required LED register value in board mode
//   +expect_display=<hex>  required hex-display register value in board mode
//   +observe_io            finish after the first retired display write; the
//                          actual board program keeps running instead of halting
//   +uart_console          check the UART byte stream against +uart_expect=<file>
//   +uart_observe          finish at that prefix, without stopping the actual CPU
//   +uart_input=<hex>      type one byte into the UART (for getc tests)
// UART expectation files use LF; the checker expects CR LF on the serial line.
//
// Pass rule (default): the program stores 1 to 0xF000_0000, then ECALL or
// EBREAK stops the CPU. Any other value is a failure; riscv-tests style
// programs store (test_number << 1) | 1.
module cpu_tb;
    import rv32i_pkg::*;

    localparam logic [31:0] RESULT_ADDR = 32'hF000_0000;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic [31:0] imem_addr, imem_rdata;
    logic        dmem_re;
    logic [3:0]  dmem_wstrb;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    retire_t     retire;
    logic        halted;
    stop_cause_t stop_cause;
    bit board_mode, observe_io, expect_leds_set, expect_display_set;
    bit have_led_write = 0, have_display_write = 0;
    logic [15:0] switches = 0, board_leds, board_display, expected_leds, expected_display;
    logic [4:0] board_buttons;
    logic [6:0] board_seg;
    logic [3:0] board_an;
    logic board_dp, bus_mapped, ram_b_en, io_en;
    logic [3:0] ram_b_wstrb, io_wstrb;
    logic [1:0] io_reg;
    logic [31:0] ram_b_addr, ram_b_wdata, ram_b_rdata, io_wdata, io_rdata;
    logic [31:0] board_cycles, board_instret;
    bit uart_mode, uart_observe;
    logic uart_en, uart_re, uart_rx_pin = 1, uart_tx_pin;
    logic [1:0] uart_reg;
    logic [3:0] uart_wstrb;
    logic [31:0] uart_wdata, uart_rdata;
    string uart_expect_file;
    byte unsigned uart_expected[$];
    int uart_received = 0;
    logic [7:0] uart_input;
    bit uart_input_set;

    rv32i_pkg::cpu_debug_status_t unused_core_debug;
    cpu_single dut (
        .debug_control('0),.debug_status(unused_core_debug),
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_re(dmem_re), .dmem_wstrb(dmem_wstrb), .dmem_addr(dmem_addr),
        .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
        .retire(retire), .halted(halted), .stop_cause(stop_cause)
    );

    // Default tests accept RAM plus the simulation result sink. Board mode
    // explicitly enables the real Phase 3 peripheral map and expected outputs.

    ram #(.PORTB_NEGEDGE(1'b1)) u_ram (
        .clk(clk),
        .a_en(1'b1), .a_addr(imem_addr), .a_rdata(imem_rdata),
        .b_en(ram_b_en), .b_wstrb(ram_b_wstrb),
        .b_addr(ram_b_addr), .b_wdata(ram_b_wdata), .b_rdata(ram_b_rdata)
    );
    logic unused_u_bus_vga_en, unused_u_bus_vga_re;
    logic [3:0] unused_u_bus_vga_wstrb;
    logic [31:0] unused_u_bus_vga_addr, unused_u_bus_vga_wdata;
    bus u_bus (
        .vga_en(unused_u_bus_vga_en), .vga_re(unused_u_bus_vga_re), .vga_wstrb(unused_u_bus_vga_wstrb), .vga_addr(unused_u_bus_vga_addr), .vga_wdata(unused_u_bus_vga_wdata),
        .vga_regs_rdata(32'b0), .vga_mem_rdata(32'b0),
        .clk(clk), .rst(rst), .re(dmem_re), .wstrb(dmem_wstrb),
        .addr(dmem_addr), .wdata(dmem_wdata), .rdata(dmem_rdata), .mapped(bus_mapped),
        .ram_en(ram_b_en), .ram_wstrb(ram_b_wstrb), .ram_addr(ram_b_addr),
        .ram_wdata(ram_b_wdata), .ram_rdata(ram_b_rdata), .io_en(io_en),
        .io_reg(io_reg), .io_wstrb(io_wstrb), .io_wdata(io_wdata), .io_rdata(io_rdata),
        .uart_en(uart_en), .uart_re(uart_re), .uart_reg(uart_reg),
        .uart_wstrb(uart_wstrb), .uart_wdata(uart_wdata), .uart_rdata(uart_rdata),
        .cycles(board_cycles), .instret(board_instret)
    );
    board_io #(.DEBOUNCE_CYCLES(3)) u_board (
        .clk(clk), .rst(rst), .en(board_mode && io_en), .reg_sel(io_reg),
        .wstrb(io_wstrb), .wdata(io_wdata), .rdata(io_rdata), .switches(switches),
        .buttons(5'b0), .buttons_clean(board_buttons), .led(board_leds),
        .display_value(board_display), .seg(board_seg), .an(board_an), .dp(board_dp)
    );
    perf_counters u_perf (
        .clk(clk), .rst(rst), .running(!rst && !halted), .retire_valid(retire.valid),
        .cycles(board_cycles), .instret(board_instret)
    );
    uart u_uart (
        .clk(clk), .rst(rst), .en(uart_mode && uart_en), .re(uart_re), .reg_sel(uart_reg),
        .wstrb(uart_wstrb), .wdata(uart_wdata), .rdata(uart_rdata), .rx(uart_rx_pin), .tx(uart_tx_pin)
    );
    logic unused_board_pins;
    assign unused_board_pins = ^{board_buttons, board_seg, board_an, board_dp};

    always #20 clk <= ~clk;  // 25 MHz

    string       program_file, vcd_file, expect_file, expect_stop;
    int unsigned max_cycles = 200000;
    bit          trace, quiet;
    int unsigned cycles = 0, retired = 0;
    bit          have_result = 0;
    logic [31:0] result_word = '0;
    logic [31:0] last_next_pc = 32'h0;
    bit          pending_rd = 0;
    logic [4:0]  pending_rd_addr;
    logic [31:0] pending_rd_data;
    // Shadow register file built only from retirement records. At the end it
    // must equal the real one, so no write can bypass the retirement record
    // (for example a faulting instruction writing rd).
    logic [31:0] shadow [0:31];
    bit          shadow_known [0:31];
    // Observe what RAM actually accepts at the falling edge, independently
    // of the retirement record checked at the following rising edge.
    logic        sampled_re = 0;
    logic [3:0]  sampled_wstrb = 0;
    logic [31:0] sampled_addr, sampled_wdata;
    logic [31:0] stopped_pc;
    stop_cause_t stopped_cause;
    bit          edge_retired = 0;

    function automatic string cause_name(input stop_cause_t c);
        case (c)
            STOP_NONE:             return "NONE";
            STOP_ECALL:            return "ECALL";
            STOP_EBREAK:           return "EBREAK";
            STOP_ILLEGAL:          return "ILLEGAL";
            STOP_MISALIGNED_FETCH: return "MISALIGNED_FETCH";
            STOP_MISALIGNED_LOAD:  return "MISALIGNED_LOAD";
            STOP_MISALIGNED_STORE: return "MISALIGNED_STORE";
            default:               return "UNKNOWN";
        endcase
    endfunction

    function automatic logic [31:0] reg_value(input int index);
        return (index == 0) ? 32'd0 : dut.u_regfile.regs[index];
    endfunction

    task automatic dump_registers();
        for (int row = 0; row < 8; row++) begin
            $display("  x%-2d %h   x%-2d %h   x%-2d %h   x%-2d %h",
                     row, reg_value(row), row + 8, reg_value(row + 8),
                     row + 16, reg_value(row + 16), row + 24, reg_value(row + 24));
        end
    endtask

    task automatic fail(input string why);
        $display("FAIL: %s (%s, %0d cycles, %0d retired, pc=%h)",
                 why, program_file, cycles, retired, dut.pc);
        dump_registers();
        $fatal(1, "%s", why);
    endtask

    task automatic check_expect_file();
        int fd, n, line_number = 0;
        logic [31:0] addr, value, got;
        string line, extra;
        int unsigned words = 0;
        fd = $fopen(expect_file, "r");
        if (fd == 0) fail($sformatf("cannot open expect file %s", expect_file));
        while (!$feof(fd)) begin
            if ($fgets(line, fd) == 0) break;
            line_number++;
            if ($sscanf(line, "%s", extra) == 0) continue; // blank line
            n = $sscanf(line, "%h %h %s", addr, value, extra);
            if (n != 2)
                fail($sformatf("malformed expect file %s line %0d: need address and value (got %0d fields, token '%s')",
                               expect_file, line_number, n, extra));
            if (addr[31:16] != 0 || addr[1:0] != 0) fail($sformatf("bad expect address %h", addr));
            got = u_ram.mem[addr[15:2]];
            if (got !== value) fail($sformatf("RAM[%h] expected %h, got %h", addr, value, got));
            words++;
        end
        $fclose(fd);
        if (words == 0) fail($sformatf("expect file %s has no entries", expect_file));
        $display("  %0d RAM words match %s", words, expect_file);
    endtask

    task automatic check_board_outputs();
        if (!have_led_write || !have_display_write)
            fail("board program did not write both LED and display registers");
        if (board_leds !== expected_leds || board_display !== expected_display)
            fail($sformatf("board outputs expected LED=%h display=%h, got LED=%h display=%h",
                           expected_leds, expected_display, board_leds, board_display));
        if (board_instret != retired || board_cycles < board_instret)
            fail("board performance counters disagree with retirement");
    endtask

    task automatic load_uart_expectation();
        int fd, character;
        fd = $fopen(uart_expect_file, "r");
        if (fd == 0) fail("cannot open UART expectation file");
        character = $fgetc(fd);
        while (character != -1) begin
            if (character == 13) fail("UART expectation must use LF line endings");
            if (character == 10) uart_expected.push_back(8'd13);
            uart_expected.push_back(8'(character));
            if (uart_expected.size() > 4096) fail("UART expectation exceeds 4096 bytes");
            character = $fgetc(fd);
        end
        $fclose(fd);
        if (uart_expected.size() == 0) fail("empty UART expectation");
    endtask

    task automatic check_uart_output();
        if (uart_received != uart_expected.size())
            fail($sformatf("UART expected %0d bytes, observed %0d", uart_expected.size(), uart_received));
        if (!uart_observe && reg_value(10) != 0) fail("UART C program returned failure in a0");
    endtask

    initial forever begin
        logic [7:0] character;
        @(negedge uart_tx_pin); #4340;
        if (!uart_mode || uart_tx_pin) fail("unexpected UART start bit");
        for (int b = 0; b < 8; b++) begin #8680; character[b] = uart_tx_pin; end
        #8680;
        if (!uart_tx_pin) fail("UART output framing error");
        if (uart_received >= uart_expected.size() || character != uart_expected[uart_received])
            fail($sformatf("UART byte %0d expected %h, got %h", uart_received,
                           uart_received < uart_expected.size() ? uart_expected[uart_received] : 8'h00, character));
        uart_received++;
    end

    initial begin
        wait (!rst);
        if (uart_input_set) begin
            repeat (217 * 12) @(negedge clk);
            uart_rx_pin = 0; repeat (217) @(negedge clk);
            for (int b = 0; b < 8; b++) begin uart_rx_pin = uart_input[b]; repeat (217) @(negedge clk); end
            uart_rx_pin = 1; repeat (217) @(negedge clk);
        end
    end

    // Checks made on every rising edge, using the values that edge commits.
    // (A task called from a testbench loop, so blocking assignments are fine.)
    task automatic monitor_edge();
        if (!rst) begin
            edge_retired = retire.valid;
            if (!halted) cycles++;
            if (dut.u_regfile.we !== (retire.valid && retire.rd_we))
                fail("register write enable disagrees with retirement");
            if (retire.valid && retire.rd_we &&
                {dut.u_regfile.waddr, dut.u_regfile.wdata} !== {retire.rd, retire.rd_wdata})
                fail("register write address/data disagrees with retirement");
            if (retire.rd_we && retire.rd == 0) fail("retirement claims a write to x0");
            if (sampled_re || sampled_wstrb != 0 || retire.mem_re || retire.mem_wstrb != 0) begin
                if (!retire.valid || {sampled_re, sampled_wstrb, sampled_addr} !==
                                    {retire.mem_re, retire.mem_wstrb, retire.mem_addr})
                    fail("accepted data access disagrees with retirement");
                if (sampled_wstrb != 0 && sampled_wdata !== retire.mem_wdata)
                    fail("accepted store data disagrees with retirement");
            end
            // The register write committed at the previous edge must be visible.
            if (pending_rd && reg_value(int'(pending_rd_addr)) !== pending_rd_data)
                fail($sformatf("x%0d should hold %h after retirement, holds %h",
                               pending_rd_addr, pending_rd_data, reg_value(int'(pending_rd_addr))));
            pending_rd = 0;

            if (retire.valid) begin
                if (retire.pc !== dut.pc || retire.instr !== imem_rdata)
                    fail("retired PC/instruction disagrees with the executing instruction");
                if (retire.pc !== last_next_pc)
                    fail($sformatf("retired pc %h but previous next_pc was %h", retire.pc, last_next_pc));
                if (retire.pc[31:16] != 0) fail($sformatf("fetch outside RAM at %h", retire.pc));
                last_next_pc = retire.next_pc;
                retired++;
                pending_rd = retire.rd_we;
                pending_rd_addr = retire.rd;
                pending_rd_data = retire.rd_wdata;
                if (retire.rd_we) begin
                    shadow[retire.rd] = retire.rd_wdata;
                    shadow_known[retire.rd] = 1;
                end

                if (retire.mem_wstrb != 0 && retire.mem_addr[31:16] != 0) begin
                    if (retire.mem_addr == RESULT_ADDR && retire.mem_wstrb == 4'b1111) begin
                        have_result = 1;
                        result_word = retire.mem_wdata;
                        // A later pass must never erase an earlier failure.
                        if (result_word !== 32'd1)
                            fail($sformatf("result word %h (test %0d failed)",
                                           result_word, result_word >> 1));
                    end else if (!((board_mode || uart_mode) && bus_mapped)) begin
                        fail($sformatf("store to unmapped address %h", retire.mem_addr));
                    end
                end
                if (retire.mem_re && retire.mem_addr[31:16] != 0 && !((board_mode || uart_mode) && bus_mapped))
                    fail($sformatf("load from unmapped address %h", retire.mem_addr));
                if (board_mode && retire.mem_wstrb[1:0] != 0) begin
                    if ({retire.mem_addr[31:2], 2'b0} == 32'h8000_0000) have_led_write = 1;
                    if ({retire.mem_addr[31:2], 2'b0} == 32'h8000_0004) have_display_write = 1;
                end

                if (trace) begin
                    string effect = "";
                    if (retire.rd_we) effect = $sformatf("x%0d=%h", retire.rd, retire.rd_wdata);
                    if (retire.mem_wstrb != 0)
                        effect = $sformatf("mem[%h]<=%h strb=%b", retire.mem_addr,
                                           retire.mem_wdata, retire.mem_wstrb);
                    else if (retire.mem_re)
                        effect = $sformatf("%s  (load %h)", effect, retire.mem_addr);
                    $display("[%6d] %h  %h  %s", cycles, retire.pc, retire.instr, effect);
                end
            end

        end
    endtask

    initial forever begin
        @(posedge clk);
        monitor_edge();
        // A halt committed on the last permitted edge is still success.
        #1;
        if (!rst && !halted && cycles >= max_cycles)
            fail($sformatf("timeout after %0d cycles", max_cycles));
    end

    initial forever begin
        @(negedge clk);
        sampled_re = !rst && dmem_re;
        sampled_wstrb = rst ? 4'b0000 : dmem_wstrb;
        sampled_addr = dmem_addr;
        sampled_wdata = dmem_wdata;
        if (halted && (dmem_re || dmem_wstrb != 0))
            fail("halted CPU attempted a data access");
    end

    initial begin
        if (!$value$plusargs("program=%s", program_file)) begin
            $fatal(1, "cpu_tb needs +program=<file.mem>");
        end
        void'($value$plusargs("max_cycles=%d", max_cycles));
        trace = $test$plusargs("trace");
        quiet = $test$plusargs("quiet");
        if ($value$plusargs("vcd=%s", vcd_file)) begin
            $dumpfile(vcd_file);
            $dumpvars(0, cpu_tb);
        end
        if (!$value$plusargs("expect=%s", expect_file)) expect_file = "";
        if (!$value$plusargs("expect_stop=%s", expect_stop)) expect_stop = "";
        board_mode = $test$plusargs("board_io");
        observe_io = $test$plusargs("observe_io");
        void'($value$plusargs("switches=%h", switches));
        expect_leds_set = $value$plusargs("expect_leds=%h", expected_leds);
        expect_display_set = $value$plusargs("expect_display=%h", expected_display);
        if (board_mode && (!expect_leds_set || !expect_display_set))
            fail("board_io requires expect_leds and expect_display");
        if (observe_io && !board_mode) fail("observe_io requires board_io");
        uart_mode = $test$plusargs("uart_console");
        uart_observe = $test$plusargs("uart_observe");
        uart_input_set = $value$plusargs("uart_input=%h", uart_input);
        if ((uart_observe || uart_input_set) && !uart_mode) fail("UART options require uart_console");
        if (uart_mode && board_mode) fail("select only one console/board observation mode");
        if (uart_mode) begin
            if (!$value$plusargs("uart_expect=%s", uart_expect_file)) fail("uart_console requires uart_expect");
            load_uart_expectation();
        end

        if (max_cycles == 0) fail("max_cycles must be positive");
        if (!(expect_stop inside {"", "ECALL", "EBREAK", "ILLEGAL", "MISALIGNED_FETCH",
                                  "MISALIGNED_LOAD", "MISALIGNED_STORE"}))
            fail($sformatf("unknown expect_stop %s", expect_stop));
        // Unwritten RAM is undefined on hardware. A nonzero poison exposes
        // tests that accidentally rely on Verilator's default zero fill.
        for (int word_index = 0; word_index < 16384; word_index++)
            u_ram.mem[word_index] = 32'ha5a5_a5a5;
        $readmemh(program_file, u_ram.mem);
        for (int r = 0; r < 32; r++) shadow_known[r] = 0;

        repeat (2) @(posedge clk);
        #1 rst = 0;

        if (uart_observe) begin
            wait (uart_received == uart_expected.size() || halted); #1;
            if (halted) fail("UART program halted before its output prefix");
            check_uart_output();
            $display("PASS: %s UART prefix: %0d bytes, CPU still running", program_file, uart_received);
            $finish;
        end

        if (observe_io) begin
            wait (have_display_write || halted); #1;
            if (halted) fail("board program stopped before output observation");
            check_board_outputs();
            $display("PASS: %s running LED=%h display=%h retired=%0d cycles=%0d", program_file,
                     board_leds, board_display, retired, cycles);
            $finish;
        end

        wait (halted);
        #1;
        stopped_pc = dut.pc;
        stopped_cause = stop_cause;
        if (edge_retired !== (stop_cause inside {STOP_ECALL, STOP_EBREAK}))
            fail("stop edge retirement disagrees with terminal/fault contract");
        // Let both RAM and register nonblocking writes settle. Keep checking
        // several full cycles: a stop must suppress the next decoded instruction.
        repeat (4) begin
            @(negedge clk); #1;
            if (dmem_re || dmem_wstrb != 0 || retire.valid || dut.u_regfile.we)
                fail("halted CPU is not quiescent");
            @(posedge clk); #1;
            if (!halted || dut.pc !== stopped_pc || stop_cause !== stopped_cause)
                fail("halted CPU changed PC or stop state");
        end

        if (expect_stop != "" && cause_name(stop_cause) != expect_stop)
            fail($sformatf("expected stop %s, got %s", expect_stop, cause_name(stop_cause)));
        if (expect_stop != "" && expect_stop != "ECALL" && expect_stop != "EBREAK") begin
            if (cause_name(stop_cause) != expect_stop)
                fail($sformatf("expected stop %s, got %s", expect_stop, cause_name(stop_cause)));
            if (have_result) fail($sformatf("fault test wrote a result word %h", result_word));
            // A fault does not retire: the PC stays on the faulting instruction.
            if (dut.pc !== last_next_pc)
                fail($sformatf("fault pc %h should equal last next_pc %h", dut.pc, last_next_pc));
        end else begin
            if (stop_cause != STOP_ECALL && stop_cause != STOP_EBREAK)
                fail($sformatf("CPU stopped with %s", cause_name(stop_cause)));
            if (dut.pc !== last_next_pc)
                fail("terminal PC disagrees with the last retirement's next PC");
            if (uart_mode) check_uart_output();
            else if (board_mode) check_board_outputs();
            else begin
                if (!have_result) fail("halted without writing a result to 0xF000_0000");
                if (result_word != 32'd1)
                    fail($sformatf("result word %h (test %0d failed)", result_word, result_word >> 1));
            end
        end
        if (expect_file != "") check_expect_file();
        for (int r = 1; r < 32; r++) begin
            if (shadow_known[r] && reg_value(r) !== shadow[r])
                fail($sformatf("x%0d holds %h but its last retired write was %h", r, reg_value(r), shadow[r]));
        end

        if (!quiet) begin
            $display("Stopped: %s at pc=%h after %0d cycles, %0d instructions retired",
                     cause_name(stop_cause), dut.pc, cycles, retired);
            dump_registers();
        end
        $display("PASS: %s stop=%s retired=%0d cycles=%0d", program_file,
                 cause_name(stop_cause), retired, cycles);
        $finish;
    end
endmodule
