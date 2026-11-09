`timescale 1ns/1ps
// Bounded COBS receiver. A single raw read port feeds both CRC and the
// outgoing byte bank. Payload padding is cleared serially before frame_valid;
// every valid frame needs at most MAX_FRAME+2 validation clocks.
module dbg_rx #(
    parameter int TIMEOUT_CYCLES = 2500000
) (
    input logic clk,rst,abort_frame,
    input logic byte_valid,
    input logic [7:0] byte_data,
    output logic byte_ready,
    output logic frame_valid,error_valid,
    output logic [7:0] error_code,
    output dbg_pkg::dbg_frame_t frame
);
    import dbg_pkg::*;
    typedef enum logic [1:0] {RECEIVE,CRC,ZERO} state_t;
    state_t state;
    logic [7:0] raw [DBG_MAX_FRAME];
    logic [7:0] payload [DBG_MAX_PAYLOAD];
    dbg_frame_t header;
    logic [8:0] raw_count,encoded_count,crc_index,body_length;
    logic [7:0] code,left,zero_index,raw_byte,payload_address,payload_data;
    logic encoded_overflow,raw_overflow,discard,payload_write;
    logic [31:0] idle_cycles,crc,received_crc;
    logic partial,timed_out;
    logic [15:0] length;
    logic unused_header_padding;
    assign unused_header_padding=^header.payload;
    assign byte_ready=state==RECEIVE;
    assign partial=encoded_count!=0 || encoded_overflow;
    assign timed_out=partial && idle_cycles>=32'(TIMEOUT_CYCLES);
    assign raw_byte=raw[crc_index];
    always_comb begin
        frame=header;
        for(int b=0;b<DBG_MAX_PAYLOAD;b=b+1) frame.payload[b*8+:8]=payload[b];
        payload_write=0; payload_address=0; payload_data=0;
        if(!rst && !abort_frame) begin
            if(state==CRC && crc_index>=9'(DBG_HEADER_BYTES) && crc_index<body_length) begin
                payload_write=1; payload_address=8'(crc_index-9'(DBG_HEADER_BYTES)); payload_data=raw_byte;
            end else if(state==ZERO) begin payload_write=1; payload_address=zero_index; end
        end
    end
    always_ff @(posedge clk) if(payload_write) payload[payload_address]<=payload_data;
    task automatic clear_packet;
        raw_count<=0; encoded_count<=0; code<=0; left<=0;
        encoded_overflow<=0; raw_overflow<=0; idle_cycles<=0;
    endtask
    task automatic append_raw(input logic [7:0] value);
        if(raw_count==9'(DBG_MAX_FRAME)) raw_overflow<=1;
        else begin
            raw[raw_count]<=value; raw_count<=raw_count+1'b1;
            if(raw_count==20) length[7:0]<=value;
            if(raw_count==21) length[15:8]<=value;
        end
    endtask
    task automatic fail(input logic [7:0] reason);
        error_valid<=1; error_code<=reason; clear_packet(); state<=RECEIVE;
    endtask
    always_ff @(posedge clk) begin
        frame_valid<=0; error_valid<=0;
        if(rst) begin
            state<=RECEIVE; clear_packet(); discard<=0;
            crc<=0; received_crc<=0; crc_index<=0; body_length<=0;
            header<='0; length<=0; zero_index<=0; error_code<=DBG_ERR_OK;
        end else if(abort_frame) begin
            clear_packet(); discard<=1; state<=RECEIVE;
        end else if(state==ZERO) begin
            if(zero_index==8'(DBG_MAX_PAYLOAD-1)) begin frame_valid<=1; state<=RECEIVE; end
            else zero_index<=zero_index+1'b1;
        end else if(state==CRC) begin
            if(crc_index<body_length) begin
                crc<=dbg_crc_byte(crc,raw_byte); crc_index<=crc_index+1'b1;
                case(crc_index)
                    0: header.version<=raw_byte; 1: header.channel<=raw_byte;
                    2: header.kind<=raw_byte; 3: header.flags<=raw_byte;
                    4: header.opcode[7:0]<=raw_byte; 5: header.opcode[15:8]<=raw_byte;
                    6: header.status[7:0]<=raw_byte; 7: header.status[15:8]<=raw_byte;
                    8: header.request_id[7:0]<=raw_byte; 9: header.request_id[15:8]<=raw_byte;
                    10: header.request_id[23:16]<=raw_byte; 11: header.request_id[31:24]<=raw_byte;
                    12: header.session_id[7:0]<=raw_byte; 13: header.session_id[15:8]<=raw_byte;
                    14: header.session_id[23:16]<=raw_byte; 15: header.session_id[31:24]<=raw_byte;
                    16: header.session_id[39:32]<=raw_byte; 17: header.session_id[47:40]<=raw_byte;
                    18: header.session_id[55:48]<=raw_byte; 19: header.session_id[63:56]<=raw_byte;
                    20: header.length[7:0]<=raw_byte; 21: header.length[15:8]<=raw_byte;
                    22: header.reserved[7:0]<=raw_byte; 23: header.reserved[15:8]<=raw_byte;
                    default: begin end
                endcase
            end else if(crc_index<body_length+9'd4) begin
                received_crc<={raw_byte,received_crc[31:8]}; crc_index<=crc_index+1'b1;
            end else begin
                state<=RECEIVE; clear_packet();
                if(~crc!=received_crc) fail(DBG_ERR_BAD_CRC);
                else if(header.version!=DBG_PROTOCOL_VERSION) fail(DBG_ERR_BAD_VERSION);
                else if(header.flags!=0 || header.reserved!=0) fail(DBG_ERR_BAD_RESERVED);
                else if(header.channel>DBG_CH_EVENT) fail(DBG_ERR_BAD_CHANNEL);
                else if(header.kind>DBG_KIND_EVENT) fail(DBG_ERR_BAD_KIND);
                else if(length==16'(DBG_MAX_PAYLOAD)) frame_valid<=1;
                else begin zero_index<=8'(length); state<=ZERO; end
            end
        end else if(discard) begin
            if(byte_valid && byte_data==0) discard<=0;
        end else if(timed_out) begin
            fail(DBG_ERR_TIMEOUT);
            if(byte_valid && byte_data!=0) begin
                encoded_count<=1; code<=byte_data; left<=byte_data-1'b1;
            end
        end else if(byte_valid) begin
            idle_cycles<=0;
            if(byte_data==0) begin
                if(partial) begin
                    if(encoded_overflow) fail(DBG_ERR_TOO_LONG);
                    else if(left!=0) fail(DBG_ERR_COBS_INVALID);
                    else if(raw_overflow) fail(DBG_ERR_TOO_LONG);
                    else if(raw_count<9'(DBG_HEADER_BYTES+DBG_CRC_BYTES)) fail(DBG_ERR_TOO_SHORT);
                    else if(length>16'(DBG_MAX_PAYLOAD) || 9'(DBG_HEADER_BYTES+DBG_CRC_BYTES)+9'(length)!=raw_count)
                        fail(DBG_ERR_BAD_LENGTH);
                    else begin
                        state<=CRC; crc<=32'hffffffff; received_crc<=0; crc_index<=0;
                        body_length<=raw_count-9'(DBG_CRC_BYTES);
                    end
                end
            end else if(!encoded_overflow) begin
                if(encoded_count==9'(DBG_MAX_ENCODED)) encoded_overflow<=1;
                else begin
                    encoded_count<=encoded_count+1'b1;
                    if(left!=0) begin append_raw(byte_data); left<=left-1'b1; end
                    else begin
                        if(code!=0 && code!=8'hff) append_raw(0);
                        code<=byte_data; left<=byte_data-1'b1;
                    end
                end
            end
        end else if(partial && idle_cycles<32'(TIMEOUT_CYCLES)) idle_cycles<=idle_cycles+1'b1;
    end
endmodule
