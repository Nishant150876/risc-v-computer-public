`timescale 1ns/1ps

// Board system. PIPELINE = 0 selects cpu_single (the Phase 3/4 system,
// unchanged); PIPELINE = 1 selects cpu_pipe with rising-edge RAM port B and
// rising-edge bus reads. CLK_HZ must match the CPU clock (UART baud and
// display scan are derived from it). rst resets peripherals;
// cpu_reset_req and the debounced centre button reset only CPU/run counters.
// mem_hold_req is a synchronous future-owner interlock, not a loader port.
// Grant is delayed until both CPU ports are quiet; release primes fetch at 0
// before execution. DEBUG_ENABLE opts into the single-cycle control boundary
// and native RAM lending; dbg_system owns the separate packet transport.
module soc #(
    parameter string INIT_FILE = "",
    parameter string FONT_FILE = "rtl/mem/font_rom.mem",
    parameter bit PIPELINE = 1'b0,
    parameter bit DEBUG_ENABLE = 1'b0,
    parameter int CLK_HZ = 25000000,
    parameter int SCAN_HZ = 4000,
    parameter int DEBOUNCE_CYCLES = 250000
) (
    input logic clk,
    input logic rst,
    input logic clk_pixel, rst_pixel,
    input logic cpu_reset_req,
    input logic mem_hold_req,
    output logic mem_hold_ack,
    input logic [15:0] switches,
    input logic [4:0] buttons,
    input logic uart_rx_pin,
    output logic uart_tx_pin,
    output logic [15:0] led,
    output logic [15:0] display_value,
    output logic [6:0] seg,
    output logic [3:0] an,
    output logic dp,
    output logic [3:0] vga_red, vga_green, vga_blue,
    output logic vga_hsync, vga_vsync,
    output logic halted,
    output rv32i_pkg::stop_cause_t stop_cause,
    output rv32i_pkg::retire_t retire,
    output logic [31:0] cycles, instret,
    input logic debug_reset_hold,
    input rv32i_pkg::cpu_debug_control_t debug_control,
    output rv32i_pkg::cpu_debug_status_t debug_status,
    input dbg_pkg::dbg_wb_request_t debug_bus,
    output dbg_pkg::dbg_wb_response_t debug_bus_response
);
    import rv32i_pkg::*;
    typedef enum logic [1:0] {RUN, HELD, PRIME} owner_state_t;
    owner_state_t owner_state;
    logic [1:0] hold_delay;
    logic cpu_rst, fetch_en, fetch_in_range, cpu_imem_en;
    logic [31:0] imem_addr, imem_data, ram_a_data;
    logic re;
    logic [3:0] wstrb;
    logic [31:0] addr, wdata, rdata;
    logic ram_en, io_en, mapped;
    logic [3:0] ram_wstrb, io_wstrb;
    logic [31:0] ram_addr, ram_wdata, ram_rdata, io_wdata, io_rdata;
    logic [1:0] io_reg;
    logic [4:0] buttons_clean;
    logic uart_en, uart_re;
    logic [1:0] uart_reg;
    logic [3:0] uart_wstrb;
    logic [31:0] uart_wdata, uart_rdata;
    logic vga_en, vga_re;
    logic [3:0] vga_wstrb;
    logic [31:0] vga_addr, vga_wdata, vga_regs_rdata, vga_mem_rdata;
    logic actual_a_en,actual_b_en;
    logic [31:0] actual_a_addr,actual_b_addr,actual_b_wdata;
    logic [3:0] actual_b_wstrb;
    initial if(DEBUG_ENABLE && PIPELINE)
        $fatal(1,"pipeline debug admission/drain is T7; use single-cycle debug profile");

    assign cpu_rst = rst || cpu_reset_req || buttons_clean[0] || mem_hold_req ||
                     owner_state != RUN || (DEBUG_ENABLE && debug_reset_hold);
    assign mem_hold_ack = !rst && mem_hold_req && owner_state == HELD && hold_delay[1];
    assign fetch_en = !mem_hold_req && owner_state != HELD;

    always_ff @(posedge clk) begin
        if (rst) begin
            owner_state <= RUN;
            hold_delay <= '0;
        end else begin
            hold_delay <= {hold_delay[0], mem_hold_req};
            case (owner_state)
                RUN: if (mem_hold_req) owner_state <= HELD;
                HELD: if (!mem_hold_req) owner_state <= PRIME;
                PRIME: owner_state <= mem_hold_req ? HELD : RUN;
                default: owner_state <= HELD;
            endcase
        end
    end

    // Match range validity to the instruction actually sampled by port A. The
    // pipeline holds port A during a stall, so the flag holds with it.
    generate
        if (PIPELINE) begin : g_cpu
            always_ff @(posedge clk) begin
                if (fetch_en && cpu_imem_en)
                    fetch_in_range <= imem_addr[31:16] == 0 && imem_addr[1:0] == 0;
            end
            cpu_pipe u_cpu (
                .clk(clk), .rst(cpu_rst), .imem_en(cpu_imem_en), .imem_addr(imem_addr),
                .imem_rdata(imem_data), .dmem_re(re), .dmem_wstrb(wstrb), .dmem_addr(addr),
                .dmem_wdata(wdata), .dmem_rdata(rdata), .retire(retire), .halted(halted),
                .stop_cause(stop_cause)
            );
        end else begin : g_cpu
            assign cpu_imem_en = 1'b1;
            always_ff @(posedge clk) begin
                fetch_in_range <= imem_addr[31:16] == 0 && imem_addr[1:0] == 0;
            end
            cpu_single #(.DEBUG_ENABLE(DEBUG_ENABLE)) u_cpu (
                .debug_control(debug_control),.debug_status(debug_status),
                .clk(clk), .rst(cpu_rst), .imem_addr(imem_addr), .imem_rdata(imem_data),
                .dmem_re(re), .dmem_wstrb(wstrb), .dmem_addr(addr), .dmem_wdata(wdata),
                .dmem_rdata(rdata), .retire(retire), .halted(halted), .stop_cause(stop_cause)
            );
        end
    endgenerate
    generate if(PIPELINE) begin : g_no_core_debug
        assign debug_status='0;
    end endgenerate
    // Out-of-range instruction fetches stop as illegal instructions; they do
    // not wrap around RAM. This is the project's stop environment, not a trap.
    assign imem_data = fetch_in_range ? ram_a_data : 32'h0000_000b;
    ram #(.INIT_FILE(INIT_FILE), .PORTB_NEGEDGE(!PIPELINE)) u_ram (
        .clk(clk), .a_en(actual_a_en),
        .a_addr(actual_a_addr), .a_rdata(ram_a_data),
        .b_en(actual_b_en), .b_wstrb(actual_b_wstrb), .b_addr(actual_b_addr),
        .b_wdata(actual_b_wdata), .b_rdata(ram_rdata)
    );
    generate if(DEBUG_ENABLE) begin : g_debug_memory
        dbg_ram_arbiter u_owner (
            .clk(clk),.rst(rst),.cpu_safe(debug_status.stopped),
            .debug_claim(debug_bus.debug_claim),.bist_claim(debug_bus.bist_claim),
            .debug_grant(debug_bus_response.debug_grant),.bist_grant(debug_bus_response.bist_grant),
            .cpu_owns(debug_bus_response.cpu_owns),
            .cpu_a_en(fetch_en && cpu_imem_en && imem_addr[31:16]==0),.cpu_a_addr(imem_addr),
            .cpu_b_en(ram_en),.cpu_b_addr(ram_addr),.cpu_b_wdata(ram_wdata),.cpu_b_wstrb(ram_wstrb),
            .ram_a_en(actual_a_en),.ram_a_addr(actual_a_addr),.ram_b_en(actual_b_en),
            .ram_b_addr(actual_b_addr),.ram_b_wdata(actual_b_wdata),.ram_b_wstrb(actual_b_wstrb),
            .ram_b_rdata(ram_rdata),.wb_cyc(debug_bus.cyc),.wb_stb(debug_bus.stb),.wb_we(debug_bus.we),
            .fault_enable(debug_bus.fault_enable && !cpu_rst),.fault_address(debug_bus.fault_address),.fault_mask(debug_bus.fault_mask),
            .fault_fired(debug_bus_response.fault_fired),.fault_original(debug_bus_response.fault_original),
            .fault_observed(debug_bus_response.fault_observed),
            .wb_adr(debug_bus.address),.wb_dat_w(debug_bus.data),.wb_sel(debug_bus.select_bytes),.wb_bist(debug_bus.bist),
            .wb_ack(debug_bus_response.ack),.wb_err(debug_bus_response.error),.wb_dat_r(debug_bus_response.data));
    end else begin : g_native_memory
        assign actual_a_en=fetch_en && cpu_imem_en && imem_addr[31:16]==0;
        assign actual_a_addr=imem_addr;
        assign actual_b_en=ram_en; assign actual_b_addr=ram_addr;
        assign actual_b_wdata=ram_wdata; assign actual_b_wstrb=ram_wstrb;
        assign debug_bus_response='0;
    end endgenerate
    bus #(.READ_POSEDGE(PIPELINE)) u_bus (
        .clk(clk), .rst(cpu_rst), .re(re), .wstrb(wstrb), .addr(addr), .wdata(wdata),
        .rdata(rdata), .mapped(mapped), .ram_en(ram_en), .ram_wstrb(ram_wstrb),
        .ram_addr(ram_addr), .ram_wdata(ram_wdata), .ram_rdata(ram_rdata),
        .io_en(io_en), .io_reg(io_reg), .io_wstrb(io_wstrb), .io_wdata(io_wdata),
        .io_rdata(io_rdata), .cycles(cycles), .instret(instret),
        .uart_en(uart_en), .uart_re(uart_re), .uart_reg(uart_reg),
        .uart_wstrb(uart_wstrb), .uart_wdata(uart_wdata), .uart_rdata(uart_rdata),
        .vga_en(vga_en), .vga_re(vga_re), .vga_wstrb(vga_wstrb),
        .vga_addr(vga_addr), .vga_wdata(vga_wdata),
        .vga_regs_rdata(vga_regs_rdata), .vga_mem_rdata(vga_mem_rdata)
    );
    board_io #(.CLK_HZ(CLK_HZ), .SCAN_HZ(SCAN_HZ), .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) u_io (
        .clk(clk), .rst(rst), .en(io_en), .reg_sel(io_reg), .wstrb(io_wstrb),
        .wdata(io_wdata), .rdata(io_rdata), .switches(switches), .buttons(buttons),
        .buttons_clean(buttons_clean), .led(led), .display_value(display_value),
        .seg(seg), .an(an), .dp(dp)
    );
    perf_counters u_perf (
        .clk(clk), .rst(cpu_rst), .running(!cpu_rst && !halted && !(DEBUG_ENABLE && debug_status.stopped)),
        .retire_valid(retire.valid), .cycles(cycles), .instret(instret)
    );
    // Console state survives CPU-only reset and reset-held RAM ownership.
    uart #(.CLK_HZ(CLK_HZ)) u_uart (
        .clk(clk), .rst(rst), .en(uart_en), .re(uart_re), .reg_sel(uart_reg),
        .wstrb(uart_wstrb), .wdata(uart_wdata), .rdata(uart_rdata),
        .rx(uart_rx_pin), .tx(uart_tx_pin)
    );

    // Display state survives CPU-only reset, just like the UART.
    vga #(.FONT_FILE(FONT_FILE), .CPU_READ_POSEDGE(PIPELINE)) u_vga (
        .clk(clk), .rst(rst), .clk_pixel(clk_pixel), .rst_pixel(rst_pixel),
        .en(vga_en), .re(vga_re), .wstrb(vga_wstrb), .addr(vga_addr), .wdata(vga_wdata),
        .regs_rdata(vga_regs_rdata), .mem_rdata(vga_mem_rdata),
        .red(vga_red), .green(vga_green), .blue(vga_blue), .hsync(vga_hsync), .vsync(vga_vsync)
    );

    logic unused_status;
    assign unused_status = ^{mapped, buttons_clean[4:1],debug_control,debug_bus};
endmodule
