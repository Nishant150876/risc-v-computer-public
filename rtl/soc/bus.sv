`timescale 1ns/1ps

// Native data bus. Only the actual RAM range is decoded: holes return zero
// and ignore writes, never alias RAM.
//   READ_POSEDGE = 0 (single-cycle CPU): MMIO reads are sampled on the
//     falling edge, just like RAM, and remain stable until CPU write-back.
//   READ_POSEDGE = 1 (pipeline): reads are sampled on the rising edge that
//     ends MEM, like the RAM's synchronous port B, and stay stable for WB.
//     A UART RX pop staged at the falling edge lands on that same rising edge,
//     so the sampled byte is the one being popped.
// Peripheral write and pop requests are unchanged in both modes.
module bus #(
    parameter bit READ_POSEDGE = 1'b0
) (
    input logic clk,
    input logic rst,
    input logic re,
    input logic [3:0] wstrb,
    input logic [31:0] addr, wdata,
    output logic [31:0] rdata,
    output logic mapped,
    output logic ram_en,
    output logic [3:0] ram_wstrb,
    output logic [31:0] ram_addr, ram_wdata,
    input logic [31:0] ram_rdata,
    output logic io_en,
    output logic [1:0] io_reg,
    output logic [3:0] io_wstrb,
    output logic [31:0] io_wdata,
    input logic [31:0] io_rdata,
    output logic uart_en, uart_re,
    output logic [1:0] uart_reg,
    output logic [3:0] uart_wstrb,
    output logic [31:0] uart_wdata,
    input logic [31:0] uart_rdata,
    output logic vga_en, vga_re,
    output logic [3:0] vga_wstrb,
    output logic [31:0] vga_addr, vga_wdata,
    input logic [31:0] vga_regs_rdata, vga_mem_rdata,
    input logic [31:0] cycles, instret
);
    logic is_ram, is_io, is_uart, is_cycles, is_instret, read_ram;
    logic is_vga_regs, is_vga_mem, read_vga;
    logic [31:0] word_addr, mmio_data;

    assign word_addr = {addr[31:2], 2'b00};
    assign is_ram = addr[31:16] == 0;
    assign is_io = addr[31:4] == 28'h8000000;
    assign is_uart = addr[31:5] == 27'h4000000 && addr[4] && addr[3:2] != 2'b11;
    assign is_cycles = word_addr == 32'h8000_0020;
    assign is_instret = word_addr == 32'h8000_0024;
    assign is_vga_regs = word_addr == 32'h8000_0028 || word_addr == 32'h8000_002c;
    assign is_vga_mem = addr[31:12] == 20'h80010 || addr[31:14] == 18'h20008;
    assign mapped = is_ram || is_io || is_uart || is_cycles || is_instret || is_vga_regs || is_vga_mem;
    assign ram_en = !rst && is_ram && (re || wstrb != 0);
    assign ram_wstrb = ram_en ? wstrb : 4'b0000;
    assign ram_addr = addr;
    assign ram_wdata = wdata;
    assign io_en = !rst && is_io && (re || wstrb != 0);
    assign io_reg = addr[3:2];
    assign io_wstrb = io_en ? wstrb : 4'b0000;
    assign io_wdata = wdata;
    assign uart_en = !rst && is_uart && (re || wstrb != 0);
    assign uart_re = uart_en && re;
    assign uart_reg = addr[3:2];
    assign uart_wstrb = uart_en ? wstrb : 4'b0;
    assign uart_wdata = wdata;

    assign vga_en = !rst && (is_vga_regs || is_vga_mem) && (re || wstrb != 0);
    assign vga_re = vga_en && re;
    assign vga_wstrb = vga_en ? wstrb : 4'b0;
    assign vga_addr = addr;
    assign vga_wdata = wdata;

    logic next_read_ram, next_read_vga;
    logic [31:0] next_mmio_data;
    always_comb begin
        next_read_ram = re && is_ram;
        next_read_vga = re && is_vga_mem;
        next_mmio_data = '0;
        if (re) begin
            if (is_io) next_mmio_data = io_rdata;
            else if (is_uart) next_mmio_data = uart_rdata;
            else if (is_cycles) next_mmio_data = cycles;
            else if (is_instret) next_mmio_data = instret;
            else if (is_vga_regs) next_mmio_data = vga_regs_rdata;
        end
    end
    generate
        if (READ_POSEDGE) begin : g_read_rise
            always_ff @(posedge clk) begin
                if (rst) begin
                    read_ram <= 1'b0;
                    read_vga <= 1'b0;
                    mmio_data <= '0;
                end else begin
                    read_ram <= next_read_ram;
                    read_vga <= next_read_vga;
                    mmio_data <= next_mmio_data;
                end
            end
        end else begin : g_read_fall
            always_ff @(negedge clk) begin
                if (rst) begin
                    read_ram <= 1'b0;
                    read_vga <= 1'b0;
                    mmio_data <= '0;
                end else begin
                    read_ram <= next_read_ram;
                    read_vga <= next_read_vga;
                    mmio_data <= next_mmio_data;
                end
            end
        end
    endgenerate
    // VGA RAM, like main RAM, supplies its own registered read result.
    // Sampling it again here would add a cycle and break a dependent load.
    assign rdata = read_ram ? ram_rdata : read_vga ? vga_mem_rdata : mmio_data;
endmodule
