`timescale 1ns/1ps
// One session and one exact replay slot. A reply is cached only after execution
// completes. External commands use a single-outstanding, held valid/ready port.
module dbg_dispatch #(
    parameter bit EXTERNAL_COMMANDS=0
) (
    input logic clk,rst,
    input logic [31:0] now_ms,
    input logic [dbg_pkg::DBG_MAX_PAYLOAD*8-1:0] identity_payload,status_payload,
    input logic request_valid,
    output logic request_ready,
    input dbg_pkg::dbg_frame_t request,
    output logic response_valid,
    input logic response_ready,
    output dbg_pkg::dbg_frame_t response,
    output logic execute_valid,
    input logic execute_ready,
    output dbg_pkg::dbg_frame_t execute_request,
    input logic result_valid,
    output logic result_ready,
    input logic [15:0] result_status,result_length,
    input logic [dbg_pkg::DBG_MAX_PAYLOAD*8-1:0] result_payload,
    output logic [31:0] rejected_requests,
    output logic [63:0] active_session
);
    import dbg_pkg::*;
    typedef enum logic [1:0] {IDLE,ISSUE,WAIT_RESULT,REPLY} state_t;
    typedef enum logic [2:0] {DROP,ANSWER,NEW_REPLY,REPLAY,EXECUTE} action_t;
    state_t state;
    action_t action;
    logic [63:0] owner;
    logic [31:0] lease_start,last_id;
    logic live;
    dbg_frame_t last_request,last_response,answer,external_answer;
    logic reply_cached;
    logic [DBG_HEADER_BYTES*8-1:0] uncached_header;
    logic [287:0] uncached_payload;
    logic unused_external_padding;
    assign unused_external_padding=^external_answer.payload;
    logic cache_valid;
    logic [15:0] lease_left;
    assign live=owner!=0 && now_ms-lease_start<DBG_LEASE_MS;
    assign active_session=live ? owner : 64'd0;
    assign lease_left=live ? 16'(DBG_LEASE_MS-(now_ms-lease_start)) : 16'd0;
    assign request_ready=state==IDLE;
    assign response_valid=state==REPLY;
    assign execute_valid=state==ISSUE;
    assign execute_request=last_request;
    assign result_ready=state==WAIT_RESULT;
    always_comb begin
        external_answer=dbg_reply(last_request,result_length>16'(DBG_MAX_PAYLOAD) ? DBG_ST_BAD_ARGUMENT : result_status);
        external_answer.length=result_length<=16'(DBG_MAX_PAYLOAD) ? result_length : 16'd0;
        response=last_response;
        if(!reply_cached) begin
            response[DBG_MAX_PAYLOAD*8+:DBG_HEADER_BYTES*8]=uncached_header;
            response.payload[0+:288]=uncached_payload;
        end
    end
    // Only length payload bytes are valid. Discovery/errors need at most 36;
    // high cached bytes are never sent for those replies and need no mux bank.
    always_comb begin
        answer=dbg_reply(request,DBG_ST_OK); action=ANSWER;
        if(request.kind!=DBG_KIND_REQUEST) action=DROP;
        else if(request.session_id==0) begin
            if(request.request_id!=0) answer.status=DBG_ST_BAD_ARGUMENT;
            else if(request.opcode!=DBG_OP_HELLO) answer.status=DBG_ST_BAD_SESSION;
            else if(request.channel!=DBG_CH_CONTROL || request.status!=0 || request.length!=0)
                answer.status=DBG_ST_BAD_ARGUMENT;
            else begin
                answer.length=36; answer.payload=identity_payload;
                answer.payload[240+:8]=live ? DBG_SESSION_OTHER : DBG_SESSION_NONE;
                answer.payload[256+:16]=lease_left;
            end
        end else if(live && owner!=request.session_id) begin
            answer.status=request.opcode==DBG_OP_HELLO ? DBG_ST_BUSY : DBG_ST_BAD_SESSION;
        end else if(!live && request.opcode!=DBG_OP_HELLO) answer.status=DBG_ST_BAD_SESSION;
        else if(request.request_id==0) answer.status=DBG_ST_BAD_ARGUMENT;
        else if(live && request.request_id==last_id) begin
            if(cache_valid && request===last_request) begin answer=last_response; action=REPLAY; end
            else answer.status=DBG_ST_ID_CONFLICT;
        end else if(live && request.request_id<last_id) answer.status=DBG_ST_STALE_REQUEST;
        else begin
            action=NEW_REPLY;
            if(request.status!=0 ||
               request.channel!=((request.opcode==DBG_OP_CONSOLE_READ || request.opcode==DBG_OP_CONSOLE_WRITE ||
                                  request.opcode==DBG_OP_CONSOLE_STATUS) ? DBG_CH_CONSOLE : DBG_CH_CONTROL))
                answer.status=DBG_ST_BAD_ARGUMENT;
            else case(request.opcode)
                DBG_OP_HELLO: begin
                    if(request.length!=0) answer.status=DBG_ST_BAD_ARGUMENT;
                    else begin
                        answer.length=36; answer.payload=identity_payload;
                        answer.payload[240+:8]=DBG_SESSION_YOURS; answer.payload[256+:16]=16'(DBG_LEASE_MS);
                    end
                end
                DBG_OP_PING: begin
                    if(request.length>16'(DBG_MAX_PING_ECHO)) answer.status=DBG_ST_BAD_ARGUMENT;
                    else begin answer.length=request.length; answer.payload=request.payload; end
                end
                DBG_OP_STATUS: begin
                    if(request.length!=0) answer.status=DBG_ST_BAD_ARGUMENT;
                    else begin answer.length=36; answer.payload=status_payload; end
                end
                default: if(EXTERNAL_COMMANDS) action=EXECUTE; else answer.status=DBG_ST_UNSUPPORTED;
            endcase
        end
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE; owner<=0; lease_start<=0; last_id<=0; cache_valid<=0;
            last_request<='0; last_response<='0; uncached_header<=0; uncached_payload<=0;
            reply_cached<=0; rejected_requests<=0;
        end else case(state)
            IDLE: if(request_valid) begin
                if(!live) begin owner<=0; cache_valid<=0; last_id<=0; end
                if(action==DROP) rejected_requests<=rejected_requests+1'b1;
                else begin
                    if(action==NEW_REPLY || action==EXECUTE) begin
                        owner<=request.session_id; lease_start<=now_ms;
                        last_id<=request.request_id; last_request<=request;
                        cache_valid<=action==NEW_REPLY;
                        if(action==NEW_REPLY) begin
                            last_response[DBG_MAX_PAYLOAD*8+:DBG_HEADER_BYTES*8]<=answer[DBG_MAX_PAYLOAD*8+:DBG_HEADER_BYTES*8];
                            last_response.payload[0+:288]<=answer.payload[0+:288];
                        end
                    end else if(action==REPLAY) lease_start<=now_ms;
                    reply_cached<=action==NEW_REPLY || action==REPLAY || action==EXECUTE;
                    uncached_header<=answer[DBG_MAX_PAYLOAD*8+:DBG_HEADER_BYTES*8];
                    uncached_payload<=answer.payload[0+:288];
                    state<=action==EXECUTE ? ISSUE : REPLY;
                end
            end
            ISSUE: if(execute_ready) state<=WAIT_RESULT;
            WAIT_RESULT: if(result_valid) begin
                last_response[DBG_MAX_PAYLOAD*8+:DBG_HEADER_BYTES*8]<=external_answer[DBG_MAX_PAYLOAD*8+:DBG_HEADER_BYTES*8];
                last_response.payload<=result_payload;
                cache_valid<=1; state<=REPLY;
            end
            REPLY: if(response_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
