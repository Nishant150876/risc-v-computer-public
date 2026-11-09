`timescale 1ns/1ps
// Bounded RAM transaction: 1/2/4-byte elements, at most 192 bytes. Every write
// is read back through actual RAM before it is counted complete.
module dbg_dma (
    input logic clk,rst,
    input logic request_valid,
    output logic request_ready,
    input logic request_write,request_bist,
    input logic [31:0] request_address,
    input logic [7:0] request_size,
    input logic [15:0] request_count,
    input logic [dbg_pkg::DBG_MAX_MEM_DATA*8-1:0] request_data,
    output logic response_valid,
    input logic response_ready,
    output logic [15:0] response_status,response_completed,
    output logic [31:0] response_address,
    output logic response_unknown,
    output logic [dbg_pkg::DBG_MAX_MEM_DATA*8-1:0] response_data,
    output dbg_pkg::dbg_wb_request_t bus,
    input dbg_pkg::dbg_wb_response_t bus_response
);
    import dbg_pkg::*;
    typedef enum logic [3:0] {IDLE,CLEAR,CLAIM,ISSUE,WAIT_WRITE,VERIFY,WAIT_READ,CAPTURE,NEXT,RELEASE,REPLY} state_t;
    state_t state;
    logic writing,bist;
    logic [31:0] address;
    logic [7:0] size;
    logic [15:0] count,index;
    logic [DBG_MAX_MEM_DATA*8-1:0] data;
    logic [31:0] outgoing,expected_word,read_word,mask;
    logic [3:0] selects;
    logic master_valid,master_ready,master_write,master_response,master_error,master_timeout,master_unknown;
    logic [31:0] master_rdata;
    logic [10:0] grant_wait;
    logic grant;
    logic [18:0] byte_count;
    logic [7:0] clear_index,sample_index;
    logic [2:0] sample_left;
    logic [31:0] sample_word;
    logic sample_failed,preflight_ok;
    logic [7:0] result_bytes[DBG_MAX_MEM_DATA];
    logic result_write;
    logic [7:0] result_address,result_byte;
    assign result_write=!rst && (state==CLEAR || state==CAPTURE);
    assign result_address=state==CLEAR ? clear_index : sample_index;
    assign result_byte=state==CAPTURE ? sample_word[7:0] : 8'd0;
    always_ff @(posedge clk) if(result_write) result_bytes[result_address]<=result_byte;
    for(genvar b=0;b<DBG_MAX_MEM_DATA;b=b+1) begin: g_result_bytes
        assign response_data[b*8+:8]=result_bytes[b];
    end
    logic [7:0] payload_offset;
    logic [31:0] payload_word;
    always_comb begin
        case(request_size)
            1: byte_count={3'd0,request_count};
            2: byte_count={2'd0,request_count,1'd0};
            default: byte_count={1'd0,request_count,2'd0};
        endcase
        case(size)
            1: payload_offset=index[7:0];
            2: payload_offset={index[6:0],1'b0};
            default: payload_offset={index[5:0],2'b0};
        endcase
        payload_word=data[{payload_offset[7:2],5'b0}+:32];
        expected_word=payload_word >> {payload_offset[1:0],3'b0};
        case(size)
            1: begin selects=4'b0001<<address[1:0]; mask=32'hff; end
            2: begin selects=4'b0011<<address[1:0]; mask=32'hffff; end
            default: begin selects=4'b1111; mask=32'hffffffff; end
        endcase
        outgoing=expected_word<<(int'(address[1:0])*8);
        read_word=(master_rdata>>(int'(address[1:0])*8))&mask;
    end
    assign grant=bist ? bus_response.bist_grant : bus_response.debug_grant;
    assign request_ready=state==IDLE;
    assign response_valid=state==REPLY;
    assign master_valid=state==ISSUE || state==VERIFY;
    assign master_write=state==ISSUE && writing;
    dbg_wb_master u_master (
        .clk(clk),.rst(rst),.request_valid(master_valid),.request_ready(master_ready),
        .request_write(master_write),.request_address({address[31:2],2'd0}),
        .request_data(outgoing),.request_select(selects),.response_valid(master_response),
        .response_ready(state==WAIT_WRITE || state==WAIT_READ),.response_data(master_rdata),
        .response_error(master_error),.response_timeout(master_timeout),.outcome_unknown(master_unknown),
        .wb_cyc(bus.cyc),.wb_stb(bus.stb),.wb_we(bus.we),.wb_adr(bus.address),.wb_dat_w(bus.data),
        .wb_sel(bus.select_bytes),.wb_ack(bus_response.ack),.wb_err(bus_response.error),.wb_dat_r(bus_response.data));
    assign bus.bist=bist;
    assign bus.fault_enable=0;
    assign bus.fault_address=0;
    assign bus.fault_mask=0;
    assign bus.debug_claim=state!=IDLE && state!=RELEASE && state!=CLEAR && state!=REPLY && !bist;
    assign bus.bist_claim=state!=IDLE && state!=RELEASE && state!=CLEAR && state!=REPLY && bist;
    logic unused_timeout_detail;
    assign unused_timeout_detail=^{master_timeout,bus_response.fault_fired,bus_response.fault_original,bus_response.fault_observed};
    task automatic finish_error(input logic [15:0] status,input logic unknown_result);
        response_status<=status; response_address<=address;
        response_unknown<=unknown_result; state<=RELEASE;
    endtask
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE; writing<=0; bist<=0; address<=0; size<=0; count<=0; index<=0;
            data<=0; grant_wait<=0; response_status<=DBG_ST_OK; response_completed<=0;
            clear_index<=0; sample_index<=0; sample_left<=0; sample_word<=0; sample_failed<=0; preflight_ok<=0;
            response_address<=0; response_unknown<=0;
        end else case(state)
            IDLE: if(request_valid) begin
                writing<=request_write; bist<=request_bist; address<=request_address;
                size<=request_size; count<=request_count; data<=request_data; index<=0;
                response_completed<=0; response_status<=DBG_ST_OK; response_address<=0;
                clear_index<=0; preflight_ok<=0; state<=CLEAR;
                response_unknown<=0; grant_wait<=0;
                if((request_size!=1 && request_size!=2 && request_size!=4) ||
                   request_count==0 || byte_count>19'(DBG_MAX_MEM_DATA)) begin
                    response_status<=DBG_ST_BAD_ARGUMENT;
                end else if((request_address&({24'd0,request_size}-1))!=0) begin
                    response_status<=DBG_ST_ALIGNMENT;
                end else if(request_address[31:16]!=0 ||
                            {1'd0,request_address}+{14'd0,byte_count}>33'h10000) begin
                    response_status<=DBG_ST_BAD_ADDRESS;
                end else preflight_ok<=1;
            end
            CLEAR: if(clear_index==8'(DBG_MAX_MEM_DATA-1)) state<=preflight_ok ? CLAIM : REPLY;
                   else clear_index<=clear_index+1'b1;
            CLAIM: begin
                if(grant) state<=ISSUE;
                else if(grant_wait==1023) finish_error(DBG_ST_BUSY,0);
                else grant_wait<=grant_wait+1'b1;
            end
            ISSUE: if(master_ready) state<=writing ? WAIT_WRITE : WAIT_READ;
            WAIT_WRITE: if(master_response) begin
                if(master_error) finish_error(master_unknown ? DBG_ST_OUTCOME_UNKNOWN : DBG_ST_BUS_ERROR,master_unknown);
                else state<=VERIFY;
            end
            VERIFY: if(master_ready) state<=WAIT_READ;
            WAIT_READ: if(master_response) begin
                if(master_error) finish_error(DBG_ST_BUS_ERROR,0);
                else begin
                    sample_word<=read_word; sample_left<=3'(size); sample_index<=payload_offset;
                    sample_failed<=writing && read_word!=(expected_word&mask);
                    state<=CAPTURE;
                end
            end
            CAPTURE: begin
                sample_word<={8'd0,sample_word[31:8]}; sample_index<=sample_index+1'b1; sample_left<=sample_left-1'b1;
                if(sample_left==1) begin
                    if(sample_failed) finish_error(DBG_ST_VERIFY_FAILED,0);
                    else begin response_completed<=response_completed+1'b1; state<=NEXT; end
                end
            end
            NEXT: if(index+1'b1==count) state<=RELEASE;
                  else begin
                      index<=index+1'b1; address<=address+{24'd0,size}; state<=ISSUE;
                  end
            RELEASE: if(bus_response.cpu_owns) state<=REPLY;
            REPLY: if(response_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
