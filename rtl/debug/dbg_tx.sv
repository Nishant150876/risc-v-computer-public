`timescale 1ns/1ps
// Registered, bounded COBS transmitter. Holds each output byte until accepted.
module dbg_tx (
    input logic clk,rst,
    input logic frame_valid,
    output logic frame_ready,
    input dbg_pkg::dbg_frame_t frame,
    output logic byte_valid,
    input logic byte_ready,
    output logic [7:0] byte_data,
    output logic busy
);
    import dbg_pkg::*;
    typedef enum logic [2:0] {IDLE,ENCODE,PATCH,FINAL_CODE,CLOSE,SEND} state_t;
    state_t state;
    dbg_frame_t held;
    logic [7:0] encoded [DBG_MAX_WIRE];
    logic [8:0] index,write_index,code_index,wire_length,send_index;
    logic [7:0] code,current;
    logic [31:0] crc;
    logic last,zero_patch,packet_end,store_enable;
    logic [8:0] store_address;
    logic [7:0] store_data;
    logic [1:0] crc_byte;
    assign crc_byte=2'(index-9'(DBG_HEADER_BYTES)-9'(held.length));
    assign frame_ready = state == IDLE;
    assign busy = state != IDLE;
    assign byte_valid = state == SEND;
    assign byte_data = encoded[send_index];
    assign last = index == 9'(DBG_HEADER_BYTES+DBG_CRC_BYTES-1)+9'(held.length);
    always_comb begin
        if (index < 9'(DBG_HEADER_BYTES)+9'(held.length))
            current=dbg_header_byte(held,int'(index));
        else current=8'((~crc) >> {crc_byte,3'b0});
        store_enable=0; store_address=0; store_data=0;
        case(state)
            ENCODE: if(current!=0) begin store_enable=1; store_address=write_index; store_data=current; end
            PATCH,FINAL_CODE: begin store_enable=1; store_address=code_index; store_data=code; end
            CLOSE: begin store_enable=1; store_address=write_index; end
            default: begin end
        endcase
    end
    // One write port permits distributed RAM instead of a multi-write FF bank.
    always_ff @(posedge clk) if(store_enable) encoded[store_address]<=store_data;
    always_ff @(posedge clk) begin
        if (rst) begin
            state<=IDLE; held<='0; index<=0; write_index<=1; code_index<=0;
            wire_length<=0; send_index<=0; code<=1; crc<=32'hffffffff; zero_patch<=0; packet_end<=0;
        end else case (state)
            IDLE: if (frame_valid) begin
                if (frame.length <= 16'(DBG_MAX_PAYLOAD)) begin
                    held<=frame; index<=0; write_index<=1; code_index<=0;
                    code<=1; crc<=32'hffffffff; zero_patch<=0; packet_end<=0; state<=ENCODE;
                end
            end
            ENCODE: begin
                if (index < 9'(DBG_HEADER_BYTES)+9'(held.length)) crc<=dbg_crc_byte(crc,current);
                index<=index+1'b1;
                if (current != 0) begin
                    write_index<=write_index+1'b1;
                    code<=code+1'b1;
                    if (code == 8'hfe) begin
                        zero_patch<=0; packet_end<=last; state<=PATCH;
                    end else if(last) state<=FINAL_CODE;
                end else begin
                    zero_patch<=1; packet_end<=last; state<=PATCH;
                end
            end
            PATCH: begin
                if(packet_end && !zero_patch) state<=CLOSE;
                else begin
                    code_index<=write_index; write_index<=write_index+1'b1; code<=1;
                    state<=packet_end ? FINAL_CODE : ENCODE;
                end
            end
            FINAL_CODE: state<=CLOSE;
            CLOSE: begin
                wire_length<=write_index+1'b1;
                send_index<=0; state<=SEND;
            end
            SEND: if (byte_ready) begin
                if (send_index+1'b1 == wire_length) state<=IDLE;
                else send_index<=send_index+1'b1;
            end
            default: state<=IDLE;
        endcase
    end
endmodule
