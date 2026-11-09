`timescale 1ns/1ps
// Byte-level packet endpoint. Console UART never enters this engine.
module dbg_packet #(
    parameter int TIMEOUT_CYCLES=2500000,
    parameter bit EXTERNAL_COMMANDS=0
) (
    input logic clk,rst,
    input logic [31:0] now_ms,
    input logic [dbg_pkg::DBG_MAX_PAYLOAD*8-1:0] identity_payload,status_payload,
    input logic abort_frame,rx_valid,
    input logic [7:0] rx_data,
    output logic rx_ready,
    output logic tx_valid,
    output logic [7:0] tx_data,
    input logic tx_ready,
    output logic execute_valid,
    input logic execute_ready,
    output dbg_pkg::dbg_frame_t execute_request,
    input logic result_valid,
    output logic result_ready,
    input logic [15:0] result_status,result_length,
    input logic [dbg_pkg::DBG_MAX_PAYLOAD*8-1:0] result_payload,
    output logic [31:0] rejected_frames,
    output logic [63:0] active_session
);
    import dbg_pkg::*;
    logic decoded_valid,decode_error,request_ready,response_valid,response_ready,tx_busy;
    logic [7:0] decode_error_code;
    dbg_frame_t decoded,response;
    logic [31:0] bad_frames,dropped_frames,rejected_requests;
    logic [DBG_MAX_PAYLOAD*8-1:0] status_combined;
    assign rejected_frames=bad_frames+dropped_frames+rejected_requests;
    always_comb begin
        status_combined=status_payload;
        status_combined[192+:32]=status_payload[192+:32]+rejected_frames;
    end
    dbg_rx #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) u_rx (
        .clk(clk),.rst(rst),.abort_frame(abort_frame),.byte_valid(rx_valid),.byte_data(rx_data),
        .byte_ready(rx_ready),.frame_valid(decoded_valid),.frame(decoded),
        .error_valid(decode_error),.error_code(decode_error_code)
    );
    dbg_dispatch #(.EXTERNAL_COMMANDS(EXTERNAL_COMMANDS)) u_dispatch (
        .clk(clk),.rst(rst),.now_ms(now_ms),.identity_payload(identity_payload),.status_payload(status_combined),
        .request_valid(decoded_valid && !tx_busy),.request_ready(request_ready),.request(decoded),
        .response_valid(response_valid),.response_ready(response_ready),.response(response),
        .execute_valid(execute_valid),.execute_ready(execute_ready),.execute_request(execute_request),
        .result_valid(result_valid),.result_ready(result_ready),.result_status(result_status),
        .result_length(result_length),.result_payload(result_payload),
        .rejected_requests(rejected_requests),.active_session(active_session)
    );
    dbg_tx u_tx (
        .clk(clk),.rst(rst),.frame_valid(response_valid),.frame_ready(response_ready),.frame(response),
        .byte_valid(tx_valid),.byte_ready(tx_ready),.byte_data(tx_data),.busy(tx_busy)
    );
    always_ff @(posedge clk) begin
        if(rst) begin bad_frames<=0; dropped_frames<=0; end
        else begin
            if(decode_error || abort_frame) bad_frames<=bad_frames+1'b1;
            if(decoded_valid && (!request_ready || tx_busy)) dropped_frames<=dropped_frames+1'b1;
        end
    end
    logic unused_error_detail;
    assign unused_error_detail=^decode_error_code;
endmodule
