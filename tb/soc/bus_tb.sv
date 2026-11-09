`timescale 1ns/1ps
module bus_tb;
    logic clk = 0, rst = 1, re = 0;
    logic [3:0] wstrb = 0, ram_wstrb, io_wstrb;
    logic [31:0] addr = 0, wdata = 0, rdata, ram_addr, ram_wdata, io_wdata;
    logic [31:0] ram_rdata = 32'h1234_5678, io_rdata = 32'h89ab_cdef;
    logic [31:0] cycles = 32'hffff_ffff, instret = 32'h7654_3210;
    logic mapped, ram_en, io_en;
    logic [1:0] io_reg;
    logic uart_en, uart_re;
    logic [1:0] uart_reg;
    logic [3:0] uart_wstrb;
    logic [31:0] uart_wdata, uart_rdata = 32'h0000_005a;
    logic vga_en, vga_re;
    logic [3:0] vga_wstrb;
    logic [31:0] vga_addr, vga_wdata;
    logic [31:0] vga_regs_rdata = 32'h0000_0008, vga_mem_rdata = 32'hcafe_f00d;
    logic unused_vga_decode;
    assign unused_vga_decode = ^{vga_en, vga_re, vga_wstrb, vga_addr, vga_wdata};
    int checks = 0;
    bus dut (.*);
    always #5 clk <= ~clk;
    task automatic access(input logic [31:0] a, input bit rd, input logic [3:0] mask,
                          input bit er, ei, em, input logic [31:0] result);
        @(posedge clk); #1; addr = a; re = rd; wstrb = mask; wdata = 32'hfedc_ba98;
        #1;
        assert ({ram_en, io_en, mapped} === {er, ei, em})
            else $fatal(1, "bus decode %h expected ram/io/mapped=%b%b%b got %b%b%b", a, er, ei, em, ram_en, io_en, mapped);
        assert (ram_addr == a && ram_wdata == wdata && io_wdata == wdata && io_reg == a[3:2])
            else $fatal(1, "bus address/data forwarding");
        assert (ram_wstrb == (er ? mask : 4'b0) && io_wstrb == (ei ? mask : 4'b0))
            else $fatal(1, "bus strobes leaked at %h", a);
        assert (uart_en == (!rst && a >= 32'h8000_0010 && a <= 32'h8000_001b && (rd || mask != 0)) &&
                uart_re == (uart_en && rd) && uart_reg == a[3:2] &&
                uart_wstrb == (uart_en ? mask : 4'b0) && uart_wdata == wdata)
            else $fatal(1, "UART bus decode or side-effect qualification at %h", a);
        @(negedge clk); #1;
        assert (rdata === result) else $fatal(1, "bus %h expected read %h got %h", a, result, rdata);
        checks++;
    endtask
    initial begin
        @(negedge clk); #1;
        assert (rdata == 0 && !ram_en && !io_en) else $fatal(1, "bus reset");
        @(posedge clk); #1; rst = 0;
        access(0, 1, 0, 1, 0, 1, ram_rdata);
        access(32'hfffc, 1, 0, 1, 0, 1, ram_rdata);
        access(32'h8000_0000, 1, 0, 0, 1, 1, io_rdata);
        access(32'h8000_0009, 1, 0, 0, 1, 1, io_rdata);
        access(32'h8000_000c, 1, 0, 0, 1, 1, io_rdata);
        access(32'h8000_0020, 1, 0, 0, 0, 1, cycles);
        access(32'h8000_0027, 1, 0, 0, 0, 1, instret);
        // A counter changing at the write-back edge must not alter the sampled read.
        @(posedge clk); #1; instret = 0;
        assert (rdata == 32'h7654_3210) else $fatal(1, "MMIO read was not sampled");
        for (int mask = 0; mask < 16; mask++) begin
            access(32'h100, 0, 4'(mask), mask != 0, 0, 1, 0);
            access(32'h8000_0004, 0, 4'(mask), 0, mask != 0, 1, 0);
        end
        access(32'h0001_0000, 1, 0, 0, 0, 0, 0);
        access(32'h1000_0000, 0, 15, 0, 0, 0, 0);
        access(32'h8000_0010, 1, 0, 0, 0, 1, uart_rdata);
        access(32'h8000_0014, 1, 0, 0, 0, 1, uart_rdata);
        access(32'h8000_001b, 1, 0, 0, 0, 1, uart_rdata);
        access(32'h8000_0018, 0, 1, 0, 0, 1, 0);
        access(32'h8000_001c, 1, 0, 0, 0, 0, 0);
        access(32'h8000_0028, 1, 0, 0, 0, 1, vga_regs_rdata);
        access(32'h8000_002c, 1, 0, 0, 0, 1, vga_regs_rdata);
        access(32'h8001_0000, 1, 0, 0, 0, 1, vga_mem_rdata);
        access(32'h8001_0fff, 1, 0, 0, 0, 1, vga_mem_rdata);
        access(32'h8001_1000, 1, 0, 0, 0, 0, 0);
        access(32'h8002_0000, 1, 0, 0, 0, 1, vga_mem_rdata);
        access(32'h8002_3fff, 1, 0, 0, 0, 1, vga_mem_rdata);
        access(32'h8002_4000, 1, 0, 0, 0, 0, 0);
        access(32'hf000_0000, 0, 15, 0, 0, 0, 0);
        @(posedge clk); #1; rst = 1;
        access(0, 1, 15, 0, 0, 1, 0);
        access(32'h8000_0018, 1, 15, 0, 0, 1, 0);
        $display("PASS: bus range boundaries, MMIO sampling, all byte strobes, unmapped holes and reset (%0d checks)", checks);
        $finish;
    end
    initial begin #10000; $fatal(1, "TIMEOUT: bus"); end
endmodule
