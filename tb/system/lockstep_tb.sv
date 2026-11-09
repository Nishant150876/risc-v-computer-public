`timescale 1ns/1ps

// Lockstep comparison: cpu_single (reference) and cpu_pipe run the same
// program image from identical RAM, each with its own native memory timing
// (single-cycle: falling-edge data port; pipeline: rising-edge data port).
//
// Compared, in order:
//   * every retirement record, field for field: PC, instruction, next PC,
//     register write (or no write), load/store enable, strobes, address, data.
//     Instructions that write no register are compared too.
//   * every data-bus access each CPU actually issues (RAM and MMIO), so an
//     extra MMIO read or write from a flushed or repeated instruction fails
//     even if retirement looks right
//   * at the stop: cause, architectural PC, x1-x31 and all of RAM
// The first mismatch prints its retirement index with both records and the
// last matching instructions, then fails.
//
// MMIO is a deterministic model shared by both sides, so CPI differences
// cannot change program behaviour: the UART never reports TX busy, RX bytes
// come from +rx=<hex bytes> (each RX read pops one, so a duplicated read
// diverges), switches read +switches=<hex>, and the cycle and instret
// counters return values that grow with each read. Writes are only recorded.
//
// Plusargs:
//   +program=<file.mem>   image (required)
//   +max_cycles=<n>       limit (default 2000000)
//   +max_retire=<n>       stop comparing after n retirements (for programs that
//                         never halt; default: run to the stop)
//   +rx=<hex>             UART input bytes, e.g. +rx=4b0d (default none)
//   +switches=<hex>       switch value (default 0)
//   +inject_mismatch=<n>  self-test: corrupt pipeline retirement n before the
//                         compare; the bench must then report index n and fail
module lockstep_tb;
    import rv32i_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #20 clk <= ~clk;

    // ------------------------------------------------------------ CPU sides
    logic [31:0] s_imem_addr, s_imem_rdata, p_imem_addr, p_imem_rdata;
    logic        p_imem_en;
    logic        s_re, p_re;
    logic [3:0]  s_wstrb, p_wstrb;
    logic [31:0] s_addr, p_addr, s_wdata, p_wdata, s_rdata, p_rdata;
    retire_t     s_retire, p_retire;
    logic        s_halted, p_halted;
    stop_cause_t s_cause, p_cause;

    cpu_debug_status_t unused_core_debug;
    cpu_single u_single (
        .debug_control('0),.debug_status(unused_core_debug),
        .clk(clk), .rst(rst), .imem_addr(s_imem_addr), .imem_rdata(s_imem_rdata),
        .dmem_re(s_re), .dmem_wstrb(s_wstrb), .dmem_addr(s_addr), .dmem_wdata(s_wdata),
        .dmem_rdata(s_rdata), .retire(s_retire), .halted(s_halted), .stop_cause(s_cause)
    );
    cpu_pipe u_pipe (
        .clk(clk), .rst(rst), .imem_en(p_imem_en), .imem_addr(p_imem_addr),
        .imem_rdata(p_imem_rdata), .dmem_re(p_re), .dmem_wstrb(p_wstrb), .dmem_addr(p_addr),
        .dmem_wdata(p_wdata), .dmem_rdata(p_rdata), .retire(p_retire), .halted(p_halted),
        .stop_cause(p_cause)
    );

    // Per-side memory system: RAM + bus + MMIO model inputs.
    logic s_ram_en, p_ram_en, s_io_en, p_io_en, s_uart_en, p_uart_en, s_uart_re, p_uart_re;
    logic s_mapped, p_mapped;
    logic [3:0]  s_ram_wstrb, p_ram_wstrb, s_io_wstrb, p_io_wstrb, s_uart_wstrb, p_uart_wstrb;
    logic [31:0] s_ram_addr, p_ram_addr, s_ram_wdata, p_ram_wdata, s_ram_rdata, p_ram_rdata;
    logic [31:0] s_io_wdata, p_io_wdata, s_uart_wdata, p_uart_wdata;
    logic [1:0]  s_io_reg, p_io_reg, s_uart_reg, p_uart_reg;
    logic [31:0] s_io_rdata, p_io_rdata, s_uart_rdata, p_uart_rdata;
    logic [31:0] s_cycles, p_cycles, s_instret, p_instret;

    ram #(.PORTB_NEGEDGE(1'b1)) s_ram (
        .clk(clk), .a_en(1'b1), .a_addr(s_imem_addr), .a_rdata(s_imem_rdata),
        .b_en(s_ram_en), .b_wstrb(s_ram_wstrb), .b_addr(s_ram_addr),
        .b_wdata(s_ram_wdata), .b_rdata(s_ram_rdata)
    );
    ram #(.PORTB_NEGEDGE(1'b0)) p_ram (
        .clk(clk), .a_en(p_imem_en), .a_addr(p_imem_addr), .a_rdata(p_imem_rdata),
        .b_en(p_ram_en), .b_wstrb(p_ram_wstrb), .b_addr(p_ram_addr),
        .b_wdata(p_ram_wdata), .b_rdata(p_ram_rdata)
    );
    logic unused_s_bus_vga_en, unused_s_bus_vga_re;
    logic [3:0] unused_s_bus_vga_wstrb;
    logic [31:0] unused_s_bus_vga_addr, unused_s_bus_vga_wdata;
    bus #(.READ_POSEDGE(1'b0)) s_bus (
        .vga_en(unused_s_bus_vga_en), .vga_re(unused_s_bus_vga_re), .vga_wstrb(unused_s_bus_vga_wstrb), .vga_addr(unused_s_bus_vga_addr), .vga_wdata(unused_s_bus_vga_wdata),
        .vga_regs_rdata(32'b0), .vga_mem_rdata(32'b0),
        .clk(clk), .rst(rst), .re(s_re), .wstrb(s_wstrb), .addr(s_addr), .wdata(s_wdata),
        .rdata(s_rdata), .mapped(s_mapped), .ram_en(s_ram_en), .ram_wstrb(s_ram_wstrb),
        .ram_addr(s_ram_addr), .ram_wdata(s_ram_wdata), .ram_rdata(s_ram_rdata),
        .io_en(s_io_en), .io_reg(s_io_reg), .io_wstrb(s_io_wstrb), .io_wdata(s_io_wdata),
        .io_rdata(s_io_rdata), .uart_en(s_uart_en), .uart_re(s_uart_re), .uart_reg(s_uart_reg),
        .uart_wstrb(s_uart_wstrb), .uart_wdata(s_uart_wdata), .uart_rdata(s_uart_rdata),
        .cycles(s_cycles), .instret(s_instret)
    );
    logic unused_p_bus_vga_en, unused_p_bus_vga_re;
    logic [3:0] unused_p_bus_vga_wstrb;
    logic [31:0] unused_p_bus_vga_addr, unused_p_bus_vga_wdata;
    bus #(.READ_POSEDGE(1'b1)) p_bus (
        .vga_en(unused_p_bus_vga_en), .vga_re(unused_p_bus_vga_re), .vga_wstrb(unused_p_bus_vga_wstrb), .vga_addr(unused_p_bus_vga_addr), .vga_wdata(unused_p_bus_vga_wdata),
        .vga_regs_rdata(32'b0), .vga_mem_rdata(32'b0),
        .clk(clk), .rst(rst), .re(p_re), .wstrb(p_wstrb), .addr(p_addr), .wdata(p_wdata),
        .rdata(p_rdata), .mapped(p_mapped), .ram_en(p_ram_en), .ram_wstrb(p_ram_wstrb),
        .ram_addr(p_ram_addr), .ram_wdata(p_ram_wdata), .ram_rdata(p_ram_rdata),
        .io_en(p_io_en), .io_reg(p_io_reg), .io_wstrb(p_io_wstrb), .io_wdata(p_io_wdata),
        .io_rdata(p_io_rdata), .uart_en(p_uart_en), .uart_re(p_uart_re), .uart_reg(p_uart_reg),
        .uart_wstrb(p_uart_wstrb), .uart_wdata(p_uart_wdata), .uart_rdata(p_uart_rdata),
        .cycles(p_cycles), .instret(p_instret)
    );

    // ------------------------------------------------------ MMIO model
    byte unsigned rx_bytes[$];
    logic [15:0] switches = 16'h0000;
    int unsigned s_rx_ptr = 0, p_rx_ptr = 0, s_counter_reads = 0, p_counter_reads = 0;

    function automatic logic [31:0] io_value(input logic [1:0] reg_sel);
        return (reg_sel == 2'd2) ? {16'd0, switches} : 32'd0;
    endfunction
    function automatic logic [31:0] uart_value(input logic [1:0] reg_sel, input int unsigned ptr);
        logic ready = ptr < rx_bytes.size();
        case (reg_sel)
            2'd1: return {30'd0, ready, 1'b0};               // never TX busy
            2'd2: return ready ? {24'd0, rx_bytes[ptr]} : 32'd0;
            default: return 32'd0;
        endcase
    endfunction
    assign s_io_rdata   = io_value(s_io_reg);
    assign p_io_rdata   = io_value(p_io_reg);
    assign s_uart_rdata = uart_value(s_uart_reg, s_rx_ptr);
    assign p_uart_rdata = uart_value(p_uart_reg, p_rx_ptr);
    // Counter reads return 1000, 2000, ... (cycles) and 100, 200, ... (instret)
    // by read number, identically on both sides.
    assign s_cycles  = 32'd1000 * (s_counter_reads + 1);
    assign p_cycles  = 32'd1000 * (p_counter_reads + 1);
    assign s_instret = 32'd100 * (s_counter_reads + 1);
    assign p_instret = 32'd100 * (p_counter_reads + 1);

    function automatic bit is_counter(input logic [31:3] a);
        return a == 29'h1000_0004;  // 0x8000_0020 and 0x8000_0024
    endfunction

    // A read is consumed on the rising edge that ends its access cycle: for the
    // single-cycle CPU the cycle it executes, for the pipeline its MEM cycle.
    always @(posedge clk) begin
        if (!rst) begin
            if (s_uart_re && s_uart_reg == 2'd2 && s_rx_ptr < rx_bytes.size()) s_rx_ptr <= s_rx_ptr + 1;
            if (p_uart_re && p_uart_reg == 2'd2 && p_rx_ptr < rx_bytes.size()) p_rx_ptr <= p_rx_ptr + 1;
            if (s_re && is_counter(s_addr[31:3])) s_counter_reads <= s_counter_reads + 1;
            if (p_re && is_counter(p_addr[31:3])) p_counter_reads <= p_counter_reads + 1;
        end
    end

    // ------------------------------------------------------ comparison
    typedef struct packed {
        logic        re;
        logic [3:0]  wstrb;
        logic [31:0] addr;
        logic [31:0] wdata;
    } access_t;

    retire_t     s_queue[$], history[$];
    access_t     s_access[$];
    string       program_file;
    int unsigned max_cycles = 2000000, max_retire = 0, inject_at = 0;
    bit          inject = 0;
    int unsigned compared = 0, accesses = 0, cycles = 0, s_retired = 0;
    int unsigned p_cycles_run = 0;

    function automatic string describe(input retire_t r);
        string text = $sformatf("%spc=%h instr=%h next=%h", r.valid ? "" : "(not valid) ",
                                r.pc, r.instr, r.next_pc);
        if (r.rd_we) text = {text, $sformatf(" x%0d=%h", r.rd, r.rd_wdata)};
        else text = {text, " (no register write)"};
        if (r.mem_wstrb != 0)
            text = {text, $sformatf(" store[%h]=%h strb=%b", r.mem_addr, r.mem_wdata, r.mem_wstrb)};
        else if (r.mem_re) text = {text, $sformatf(" load[%h]", r.mem_addr)};
        return text;
    endfunction

    task automatic fail(input string why);
        $display("FAIL: lockstep %s: %s (compared %0d retirements, cycle %0d)",
                 program_file, why, compared, cycles);
        foreach (history[i]) $display("  ok   #%0d %s", compared - history.size() + i, describe(history[i]));
        $fatal(1, "%s", why);
    endtask

    function automatic access_t sample(input logic re, input logic [3:0] wstrb,
                                       input logic [31:0] addr, input logic [31:0] wdata);
        access_t a;
        a.re = re;
        a.wstrb = wstrb;
        a.addr = addr;
        a.wdata = (wstrb != 0) ? wdata : 32'd0;
        return a;
    endfunction

    // Both CPUs present a data access for a whole cycle; sample it once per
    // cycle, at the falling edge (where RAM/MMIO accept single-cycle ones).
    initial forever begin
        @(negedge clk);
        if (!rst) begin
            if (s_re || s_wstrb != 0) s_access.push_back(sample(s_re, s_wstrb, s_addr, s_wdata));
            if (p_re || p_wstrb != 0) begin
                access_t got = sample(p_re, p_wstrb, p_addr, p_wdata), want;
                if (s_access.size() == 0)
                    fail($sformatf("pipeline bus access %s %h has no reference access",
                                   p_re ? "read" : "write", p_addr));
                want = s_access.pop_front();
                if (got !== want)
                    fail($sformatf("bus access %0d: pipeline re=%b strb=%b addr=%h data=%h, reference re=%b strb=%b addr=%h data=%h",
                                   accesses, got.re, got.wstrb, got.addr, got.wdata,
                                   want.re, want.wstrb, want.addr, want.wdata));
                accesses++;
            end
        end
    end

    initial forever begin
        @(posedge clk);
        if (!rst) begin
            cycles++;
            if (!p_halted) p_cycles_run++;
            if (s_retire.valid && (max_retire == 0 || s_retired < max_retire)) begin
                s_queue.push_back(s_retire);
                s_retired++;
            end
            if (p_retire.valid && (max_retire == 0 || compared < max_retire)) begin
                retire_t got = p_retire, want;
                if (inject && compared == inject_at) got.rd_wdata = got.rd_wdata ^ 32'h1;
                if (s_queue.size() == 0)
                    fail($sformatf("pipeline retired #%0d %s before the reference", compared, describe(got)));
                want = s_queue.pop_front();
                if (got !== want) begin
                    $display("  reference #%0d %s", compared, describe(want));
                    $display("  pipeline  #%0d %s", compared, describe(got));
                    fail($sformatf("first mismatch at retirement #%0d, pc %h", compared, want.pc));
                end
                history.push_back(got);
                if (history.size() > 4) void'(history.pop_front());
                compared++;
            end
        end
    end

    initial begin
        string rx_text;
        if (!$value$plusargs("program=%s", program_file)) $fatal(1, "lockstep_tb needs +program=<file.mem>");
        void'($value$plusargs("max_cycles=%d", max_cycles));
        void'($value$plusargs("max_retire=%d", max_retire));
        void'($value$plusargs("switches=%h", switches));
        inject = $value$plusargs("inject_mismatch=%d", inject_at);
        if ($value$plusargs("rx=%s", rx_text)) begin
            if (rx_text.len() % 2 != 0) $fatal(1, "+rx needs whole hex bytes");
            for (int i = 0; i < rx_text.len(); i += 2) rx_bytes.push_back(8'(rx_text.substr(i, i + 1).atohex()));
        end
        // Identical poisoned images on both sides.
        for (int w = 0; w < 16384; w++) begin
            s_ram.mem[w] = 32'ha5a5_a5a5;
            p_ram.mem[w] = 32'ha5a5_a5a5;
        end
        $readmemh(program_file, s_ram.mem);
        $readmemh(program_file, p_ram.mem);

        repeat (2) @(posedge clk);
        #1 rst = 0;

        while (!(p_halted && s_halted) && !(max_retire != 0 && compared >= max_retire)) begin
            @(posedge clk); #1;
            if (cycles >= max_cycles) fail($sformatf("timeout after %0d cycles", max_cycles));
        end
        if (max_retire != 0 && compared >= max_retire) begin
            if (inject && inject_at < compared) fail("injected mismatch was not detected");
            $display("PASS: %s lockstep: %0d retirements and %0d bus accesses match (comparison window)",
                     program_file, compared, accesses);
            $finish;
        end
        repeat (2) @(posedge clk); #1;
        if (s_queue.size() != 0)
            fail($sformatf("reference retired %0d more instructions, next %s", s_queue.size(), describe(s_queue[0])));
        if (s_access.size() != 0) fail($sformatf("reference issued %0d more bus accesses", s_access.size()));
        if (s_cause !== p_cause) fail($sformatf("stop cause: reference %0d, pipeline %0d", s_cause, p_cause));
        if (u_single.pc !== u_pipe.pc)
            fail($sformatf("stop PC: reference %h, pipeline %h", u_single.pc, u_pipe.pc));
        for (int r = 1; r < 32; r++)
            if (u_single.u_regfile.regs[r] !== u_pipe.u_regfile.regs[r])
                fail($sformatf("x%0d: reference %h, pipeline %h", r, u_single.u_regfile.regs[r],
                               u_pipe.u_regfile.regs[r]));
        for (int w = 0; w < 16384; w++)
            if (s_ram.mem[w] !== p_ram.mem[w])
                fail($sformatf("RAM[%h]: reference %h, pipeline %h", w * 4, s_ram.mem[w], p_ram.mem[w]));
        if (inject) fail("injected mismatch was not detected");
        $display("PASS: %s lockstep: %0d retirements, %0d bus accesses, registers and RAM match; stop %0d; pipeline %0d cycles",
                 program_file, compared, accesses, p_cause, p_cycles_run);
        $finish;
    end

    logic unused;
    assign unused = ^{s_mapped, p_mapped, s_io_en, p_io_en, s_io_wstrb, p_io_wstrb, s_io_wdata,
                      p_io_wdata, s_uart_en, p_uart_en, s_uart_wstrb, p_uart_wstrb, s_uart_wdata,
                      p_uart_wdata};
endmodule
