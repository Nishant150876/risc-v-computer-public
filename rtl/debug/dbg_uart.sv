`timescale 1ns/1ps
// Dedicated packet UART; use board/global reset, never CPU-only reset.
module dbg_uart #(
    parameter int CLK_HZ=25000000,
    parameter int BAUD=115200,
    parameter bit EXTERNAL_COMMANDS=0
) (
    input logic clk,rst,rx,
    output logic tx,
    input logic [dbg_pkg::DBG_MAX_PAYLOAD*8-1:0] identity_payload,status_payload,
    output logic execute_valid,
    input logic execute_ready,
    output dbg_pkg::dbg_frame_t execute_request,
    input logic result_valid,
    output logic result_ready,
    input logic [15:0] result_status,result_length,
    input logic [dbg_pkg::DBG_MAX_PAYLOAD*8-1:0] result_payload,
    output logic [31:0] rejected_frames,uart_overruns,
    output logic [63:0] active_session
);
    import dbg_pkg::*;
    localparam int CLKS_PER_BIT=(CLK_HZ+BAUD/2)/BAUD;
    localparam int CW=$clog2(CLK_HZ/1000);
    logic [CW-1:0] ms_divider;
    logic [31:0] now_ms;
    logic rx_valid,rx_ready,framing_error,tx_valid,tx_busy;
    logic [7:0] rx_data,tx_data;
    logic [DBG_MAX_PAYLOAD*8-1:0] status_combined;
    initial begin
        if(CLK_HZ%1000!=0 || CLK_HZ<1000) $fatal(1,"debug clock needs whole millisecond ticks");
        if(CLKS_PER_BIT*10<DBG_MAX_FRAME+32) $fatal(1,"UART too fast for bounded packet validation");
    end
    always_comb begin
        status_combined=status_payload;
        status_combined[224+:32]=status_payload[224+:32]+uart_overruns;
    end
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk),.rst(rst),.rx(rx),.data(rx_data),.valid(rx_valid),.framing_error(framing_error));
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk),.rst(rst),.start(tx_valid && !tx_busy),.data(tx_data),.tx(tx),.busy(tx_busy));
    dbg_packet #(.TIMEOUT_CYCLES(CLK_HZ/10),.EXTERNAL_COMMANDS(EXTERNAL_COMMANDS)) u_packet (
        .clk(clk),.rst(rst),.now_ms(now_ms),.identity_payload(identity_payload),.status_payload(status_combined),
        .abort_frame(framing_error || (rx_valid && !rx_ready)),
        .rx_valid(rx_valid),.rx_data(rx_data),.rx_ready(rx_ready),
        .tx_valid(tx_valid),.tx_data(tx_data),.tx_ready(!tx_busy),
        .execute_valid(execute_valid),.execute_ready(execute_ready),.execute_request(execute_request),
        .result_valid(result_valid),.result_ready(result_ready),.result_status(result_status),
        .result_length(result_length),.result_payload(result_payload),
        .rejected_frames(rejected_frames),.active_session(active_session)
    );
    always_ff @(posedge clk) begin
        if(rst) begin ms_divider<=0; now_ms<=0; uart_overruns<=0; end
        else begin
            if(ms_divider==CW'(CLK_HZ/1000-1)) begin ms_divider<=0; now_ms<=now_ms+1'b1; end
            else ms_divider<=ms_divider+1'b1;
            if(rx_valid && !rx_ready) uart_overruns<=uart_overruns+1'b1;
        end
    end
endmodule
