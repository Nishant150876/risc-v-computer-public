`timescale 1ns/1ps

// Phase 3 FPGA top. Keep basys3_top as the original Phase 0 blink target.
// PIPELINE selects the CPU (0: cpu_single, the Phase 3/4 default; 1: cpu_pipe).
// CPU_HZ is the MMCM output; the UART and display scan follow it.
module basys3_soc #(
    parameter string INIT_FILE = "",
    parameter string FONT_FILE = "rtl/mem/font_rom.mem",
    parameter bit PIPELINE = 1'b0,
    parameter int CPU_HZ = 25000000,
    parameter int DEBOUNCE_CYCLES = 250000
) (
    input logic clk,
    input logic [15:0] sw,
    input logic btnC, btnU, btnL, btnR, btnD,
    input logic RsRx,
    output logic RsTx,
    output logic [15:0] led,
    output logic [6:0] seg,
    output logic [3:0] an,
    output logic dp,
    output logic [3:0] vgaRed, vgaGreen, vgaBlue,
    output logic Hsync, Vsync
);
    logic clk_cpu, clk_pixel, locked;
    logic rst_pixel = 1'b1;
    (* ASYNC_REG = "TRUE" *) logic [1:0] pixel_reset_pipe = 2'b11;
    logic rst = 1'b1;
    // External clock-status boundary: async assertion on lost lock, deassert
    // only after two CPU edges. All ordinary design reset inputs are synchronous.
    (* ASYNC_REG = "TRUE" *) logic [1:0] reset_pipe = 2'b11;
    clock_gen #(.CPU_HZ(CPU_HZ)) u_clock (.clk(clk), .rst(1'b0), .clk_cpu(clk_cpu),
                                             .clk_pixel(clk_pixel), .locked(locked));
    always_ff @(posedge clk_cpu or negedge locked) begin
        if (!locked) reset_pipe <= 2'b11;
        else reset_pipe <= {reset_pipe[0], 1'b0};
    end
    // Plain synchronous stage removes async-set logic from BRAM controls
    // (REQP-1839). Initial reset is asserted; release now takes three edges.
    always_ff @(posedge clk_cpu) rst <= reset_pipe[1];

    always_ff @(posedge clk_pixel or negedge locked) begin
        if (!locked) pixel_reset_pipe <= 2'b11;
        else pixel_reset_pipe <= {pixel_reset_pipe[0], 1'b0};
    end
    always_ff @(posedge clk_pixel) rst_pixel <= pixel_reset_pipe[1];

    logic mem_hold_ack, halted;
    logic [15:0] display_value;
    logic [31:0] cycles, instret;
    rv32i_pkg::stop_cause_t stop_cause;
    rv32i_pkg::retire_t retire;
    rv32i_pkg::cpu_debug_status_t unused_debug_status;
    dbg_pkg::dbg_wb_response_t unused_debug_bus;
    soc #(.INIT_FILE(INIT_FILE), .FONT_FILE(FONT_FILE), .PIPELINE(PIPELINE), .CLK_HZ(CPU_HZ),
          .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) u_soc (
        .debug_reset_hold(1'b0),.debug_control('0),.debug_status(unused_debug_status),
        .debug_bus('0),.debug_bus_response(unused_debug_bus),
        .clk(clk_cpu), .rst(rst), .clk_pixel(clk_pixel), .rst_pixel(rst_pixel), .cpu_reset_req(1'b0),
        .mem_hold_req(1'b0), .mem_hold_ack(mem_hold_ack),
        .switches(sw), .buttons({btnD, btnR, btnL, btnU, btnC}),
        .uart_rx_pin(RsRx), .uart_tx_pin(RsTx),
        .led(led), .display_value(display_value), .seg(seg), .an(an), .dp(dp),
        .vga_red(vgaRed), .vga_green(vgaGreen), .vga_blue(vgaBlue), .vga_hsync(Hsync), .vga_vsync(Vsync),
        .halted(halted), .stop_cause(stop_cause), .retire(retire), .cycles(cycles), .instret(instret)
    );
    logic unused_observation;
    assign unused_observation = ^{mem_hold_ack, halted, stop_cause, retire,
                                 display_value, cycles, instret};
endmodule
