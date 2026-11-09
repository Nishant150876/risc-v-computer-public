`timescale 1ns/1ps
// Board-independent, single-cycle debug integration. Byte I/O belongs to the
// dedicated packet UART; console pins remain a separate, ordinary UART.
// No physical debug pin assignment is implied by this simulation build target.
module dbg_system #(
    parameter int CLK_HZ=25000000,
    parameter int TIMEOUT_CYCLES=2500000
) (
    input logic clk,rst,
    input logic [31:0] now_ms,
    input logic rx_valid,abort_frame,
    input logic [7:0] rx_data,
    output logic rx_ready,tx_valid,
    output logic [7:0] tx_data,
    input logic tx_ready,
    input logic cpu_reset_req,console_rx,
    output logic console_tx,
    input logic [15:0] switches,
    input logic [4:0] buttons,
    output logic [15:0] led,display_value,
    output rv32i_pkg::retire_t retire,
    output logic [31:0] rejected_frames
);
    import dbg_pkg::*;
    import rv32i_pkg::*;
    logic execute_valid,execute_ready,result_valid,result_ready,debug_reset_hold,cpu_terminal;
    logic [15:0] result_status,result_length;
    logic [DBG_MAX_PAYLOAD*8-1:0] identity_payload,status_payload,result_payload;
    logic [63:0] active_session;
    dbg_frame_t execute_request;
    cpu_debug_control_t debug_control;
    cpu_debug_status_t cpu;
    stop_cause_t stop_cause;
    dbg_wb_request_t bus;
    dbg_wb_response_t bus_response;
    logic mem_hold_ack,dp,vga_hsync,vga_vsync;
    logic [6:0] seg;
    logic [3:0] an,vga_red,vga_green,vga_blue;
    logic [31:0] cycles,instret;
    logic unused_board;
    assign unused_board=^{mem_hold_ack,dp,seg,an,vga_red,vga_green,vga_blue,vga_hsync,vga_vsync,cycles,instret};
    dbg_packet #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES),.EXTERNAL_COMMANDS(1)) u_packet(.*);
    dbg_executor #(.CLK_HZ(CLK_HZ)) u_executor(.*);
    soc #(.DEBUG_ENABLE(1),.CLK_HZ(CLK_HZ)) u_soc (
        .clk(clk),.rst(rst),.clk_pixel(clk),.rst_pixel(rst),.cpu_reset_req(cpu_reset_req),
        .mem_hold_req(1'b0),.mem_hold_ack(mem_hold_ack),.switches(switches),.buttons(buttons),
        .uart_rx_pin(console_rx),.uart_tx_pin(console_tx),.led(led),.display_value(display_value),
        .seg(seg),.an(an),.dp(dp),.vga_red(vga_red),.vga_green(vga_green),.vga_blue(vga_blue),
        .vga_hsync(vga_hsync),.vga_vsync(vga_vsync),.halted(cpu_terminal),.stop_cause(stop_cause),
        .retire(retire),.cycles(cycles),.instret(instret),.debug_reset_hold(debug_reset_hold),
        .debug_control(debug_control),.debug_status(cpu),.debug_bus(bus),.debug_bus_response(bus_response));
endmodule
