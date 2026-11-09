`timescale 1ns/1ps
// Single-cycle debug profile: controlled CPU state, checked RAM transactions
// and ordered program loading. Pipeline control is deliberately not advertised.
module dbg_executor #(
    parameter int CLK_HZ=25000000,
    parameter logic [31:0] BUILD_ID=32'h44330001
) (
    input logic clk,rst,
    input logic execute_valid,
    output logic execute_ready,
    input dbg_pkg::dbg_frame_t execute_request,
    output logic result_valid,
    input logic result_ready,
    output logic [15:0] result_status,result_length,
    output logic [dbg_pkg::DBG_MAX_PAYLOAD*8-1:0] result_payload,
    input logic [63:0] active_session,
    output logic [dbg_pkg::DBG_MAX_PAYLOAD*8-1:0] identity_payload,status_payload,
    output logic debug_reset_hold,
    output rv32i_pkg::cpu_debug_control_t debug_control,
    input rv32i_pkg::cpu_debug_status_t cpu,
    input logic cpu_terminal,
    input rv32i_pkg::stop_cause_t stop_cause,
    input rv32i_pkg::retire_t retire,
    output dbg_pkg::dbg_wb_request_t bus,
    input dbg_pkg::dbg_wb_response_t bus_response
);
    import dbg_pkg::*;
    import rv32i_pkg::*;
    typedef enum logic [4:0] {
        IDLE,HALT_WAIT,STEP_ADMIT,STEP_WAIT,RESUME_WAIT,RESET_WAIT,RUN_PRIME,
        REG_WRITE_WAIT,REG_WRITE_CHECK,
        DMA_START,DMA_WAIT,VERIFY_START,VERIFY_ISSUE,VERIFY_WAIT,VERIFY_CRC,BSS_START,BSS_ISSUE,BSS_WAIT,
        OBSERVE_WAIT,BIST_WAIT,LOAD_NAME
    } state_t;
    state_t state;
    logic [15:0] opcode,timer;
    logic [31:0] generation,load_id,image_bytes,expected_crc,bss_address,bss_bytes,received_bytes;
    logic image_valid,image_modified,loading,operation_active,abort_pending;
    logic [31:0] verify_offset,crc,observed_crc,zero_address,zero_remaining;
    logic [15:0] crc_index,verify_bytes;
    logic [63:0] operation_id;
    logic [7:0] operation_state,cpu_state,halt_reason;
    logic [15:0] operation_status;
    logic [31:0] operation_completed,operation_address;
    logic previous_stopped,previous_reset;
    logic [4:0] reply_reg_start,reply_reg_number;
    logic [1:0] reply_reg_byte;
    logic [4:0] reply_trace_byte;
    logic [31:0] reply_reg_word,reply_trace_generation;
    logic [31:0] register_expected;
    logic dma_valid,dma_ready,dma_write,dma_response,dma_unknown;
    logic [31:0] dma_address,dma_error_address;
    logic [7:0] dma_size;
    logic [15:0] dma_count,dma_status,dma_completed;
    logic [DBG_MAX_MEM_DATA*8-1:0] dma_data,dma_result;
    logic saved_valid;
    logic [18:0] request_bytes;
    logic [15:0] memory_bytes;
    logic [32:0] request_end;
    logic [31:0] crc_next;
    logic [15:0] next_verify_bytes;
    logic [31:0] capabilities;
    // Replies use one byte writer, avoiding a parallel 256-byte response crossbar.
    typedef enum logic [2:0] {REPLY_META,REPLY_REGISTERS,REPLY_MEMORY,REPLY_COUNTERS,REPLY_COUNTER_SLICE,REPLY_TRACE} reply_kind_t;
    reply_kind_t reply_kind;
    logic reply_busy;
    logic [7:0] reply_index,reply_byte;
    logic [5:0] reply_counter_offset,reply_counter_index;
    logic [383:0] reply_meta;
    logic [7:0] reply_bytes[DBG_MAX_PAYLOAD];
    typedef enum logic [1:0] {INPUT_ZERO,INPUT_MEM,INPUT_LOAD,INPUT_RESTORE} dma_input_t;
    dma_input_t dma_source;
    logic [(DBG_MAX_MEM_DATA+12)*8-1:0] held_payload;
    always_ff @(posedge clk) if(execute_valid && execute_ready)
        held_payload<=execute_request.payload[0+:(DBG_MAX_MEM_DATA+12)*8];
    assign reply_reg_byte=2'(reply_index-8'd8);
    assign reply_reg_number=5'((reply_index-8'd8)>>2);
    assign reply_trace_byte=5'(reply_index-8'd12);
    assign reply_counter_index=reply_counter_offset+6'(reply_index-8'd12);
    always_comb begin
        dma_data='0;
        case(dma_source)
            INPUT_MEM: dma_data=held_payload[64+:DBG_MAX_MEM_DATA*8];
            INPUT_LOAD: dma_data=held_payload[96+:DBG_MAX_MEM_DATA*8];
            INPUT_RESTORE: dma_data[0+:32]=fault_saved;
            default: begin end
        endcase
        reply_byte=0;
        case(reply_kind)
            REPLY_META: if(reply_index<48) reply_byte=reply_meta[{reply_index[5:0],3'b0}+:8];
            REPLY_REGISTERS: if(reply_index<8) reply_byte=reply_meta[{reply_index[5:0],3'b0}+:8];
                else reply_byte=reply_reg_byte==0 ? cpu.reg_rdata[7:0] : 8'(reply_reg_word >> {reply_reg_byte,3'b0});
            REPLY_TRACE: if(reply_index<12) reply_byte=reply_meta[{reply_index[5:0],3'b0}+:8];
                else reply_byte=trace_record[{reply_trace_byte,3'b0}+:8];
            REPLY_MEMORY: if(reply_index<8) reply_byte=reply_meta[{reply_index[5:0],3'b0}+:8];
                else reply_byte=dma_result[{8'(reply_index-8'd8),3'b0}+:8];
            REPLY_COUNTERS: reply_byte=counter_capture[{reply_index[5:0],3'b0}+:8];
            REPLY_COUNTER_SLICE: if(reply_index<12) reply_byte=reply_meta[{reply_index[5:0],3'b0}+:8];
                else reply_byte=counter_capture[{reply_counter_index,3'b0}+:8];
            default: begin end
        endcase
        if({8'd0,reply_index}>=result_length) reply_byte=0;
    end
    always_ff @(posedge clk) if(reply_busy) reply_bytes[reply_index]<=reply_byte;
    for(genvar byte_number=0;byte_number<DBG_MAX_PAYLOAD;byte_number=byte_number+1) begin: g_reply_bytes
        assign result_payload[byte_number*8+:8]=reply_bytes[byte_number];
    end
    logic capture_counters,freeze_trace,arm_trace,trace_frozen;
    logic [31:0] counter_generation,trace_generation;
    logic [511:0] counter_capture;
    logic [383:0] trace_descriptor;
    logic [8:0] trace_count;
    logic [7:0] trace_index;
    logic [255:0] trace_record;
    dbg_wb_request_t dma_bus,bist_bus;
    logic bist_start,bist_ready,bist_active,bist_done,bist_alu_test;
    logic [7:0] bist_id,bist_phase,operation_kind;
    logic [15:0] bist_status;
    logic [31:0] bist_address,bist_bytes,bist_completed,bist_first,bist_expected,bist_observed,bist_a,bist_b;
    alu_op_t bist_alu_op;
    logic fault_armed,fault_active,fault_fired,fault_restore_pending,fault_restored;
    logic [7:0] fault_state;
    logic [31:0] arm_id,fault_address,fault_mask,fault_saved,fault_original,fault_observed,fault_restored_value;
    logic [31:0] fault_triggers;
    logic [63:0] fault_operation;
    logic [15:0] fault_detection,fault_cleanup;
    logic [5:0] name_index;
    logic [2:0] utf8_needed;
    logic [7:0] utf8_min,utf8_max,name_byte;
    assign name_byte=held_payload[(40+int'(name_index))*8+:8];
    logic unused_bist_handshake;
    assign unused_bist_handshake=^{bist_ready,bist_active};
    logic unused_transport_header;
    assign unused_transport_header=^{execute_request.version,execute_request.channel,execute_request.kind,
        execute_request.flags,execute_request.status,execute_request.request_id,execute_request.session_id,execute_request.reserved,held_payload,execute_request.payload};
    assign capabilities=DBG_CAP_BASE_STATUS|DBG_CAP_RAM_ACCESS|DBG_CAP_LOADER|
                        DBG_CAP_HALT_RESUME|DBG_CAP_REG_ACCESS|DBG_CAP_STEP|DBG_CAP_BREAKPOINTS|
                        DBG_CAP_RETIRE_TRACE|DBG_CAP_BASE_COUNTERS|DBG_CAP_PERF64|
                        DBG_CAP_MEM_BIST|DBG_CAP_ALU_BIST|DBG_CAP_FAULT_INJECT;
    always_comb begin
        bus=state==BIST_WAIT ? bist_bus : dma_bus;
        bus.fault_enable=fault_active && !cpu.reset_held;
        bus.fault_address=fault_address; bus.fault_mask=fault_mask;
    end
    assign execute_ready=!result_valid && !reply_busy && (state==IDLE || operation_active);
    assign dma_valid=state==DMA_START || ((state==VERIFY_ISSUE || state==BSS_ISSUE) && !abort_pending);
    assign request_end={1'b0,execute_request.payload[0+:32]}+{14'd0,request_bytes};
    assign crc_next=dbg_crc_byte(crc,dma_result[int'(crc_index)*8+:8]);
    assign next_verify_bytes=image_bytes-verify_offset>DBG_MAX_MEM_DATA ?
                             16'(DBG_MAX_MEM_DATA) : 16'(image_bytes-verify_offset);
    always_comb begin
        case(execute_request.payload[32+:8])
            1: request_bytes={3'd0,execute_request.payload[48+:16]};
            2: request_bytes={2'd0,execute_request.payload[48+:16],1'd0};
            default: request_bytes={1'd0,execute_request.payload[48+:16],2'd0};
        endcase
        if(cpu.reset_held || debug_reset_hold) cpu_state=DBG_CPU_RESET_HELD;
        else if(cpu_terminal) cpu_state=(stop_cause==STOP_ECALL || stop_cause==STOP_EBREAK) ? DBG_CPU_TERMINATED : DBG_CPU_ERROR;
        else if(cpu.stopped) cpu_state=cpu.breakpoint ? DBG_CPU_BREAKPOINT : DBG_CPU_HALTED;
        else if(state==STEP_ADMIT || state==STEP_WAIT) cpu_state=DBG_CPU_STEPPING;
        else if(state==HALT_WAIT) cpu_state=DBG_CPU_HALT_REQUESTED;
        else cpu_state=DBG_CPU_RUNNING;
        identity_payload=dbg_identity(BUILD_ID,32'(CLK_HZ),capabilities,cpu_state);
        identity_payload[192+:8]=2;
        identity_payload[200+:8]=1;
        identity_payload[208+:16]=256;
        identity_payload[224+:8]=cpu_state;
        identity_payload[232+:8]=operation_state;
        identity_payload[272+:16]=16'h00ef; // no asynchronous injection operation state
        status_payload='0;
        status_payload[0+:8]=cpu_state;
        status_payload[8+:8]=cpu.breakpoint ? DBG_HALT_BREAKPOINT :
                                  (cpu_terminal && stop_cause!=STOP_ECALL && stop_cause!=STOP_EBREAK) ? DBG_HALT_FAULT : halt_reason;
        status_payload[16+:8]=operation_state;
        status_payload[24+:8]=8'(DBG_VALID_NEXT_PC) | (cpu.last_pc_valid ? 8'(DBG_VALID_LAST_PC) : 8'd0) |
                               (image_valid ? 8'(DBG_VALID_IMAGE) : 8'd0) | (image_modified ? 8'(DBG_VALID_MODIFIED) : 8'd0);
        status_payload[32+:32]=cpu.last_pc;
        status_payload[64+:32]=cpu.next_pc;
        status_payload[96+:32]=load_id;
        status_payload[128+:64]=operation_id;
        status_payload[256+:32]=generation;
    end
    dbg_observer u_observer (
        .clk(clk),.rst(rst),.cpu_reset(cpu.reset_held),.running(!cpu.stopped),.retire(retire),.stop_cause(stop_cause),
        .capture_counters(capture_counters),.freeze_trace(freeze_trace),.arm_trace(arm_trace),.clear_trace(arm_trace),
        .counter_generation(counter_generation),.trace_generation(trace_generation),.counters(counter_capture),
        .trace_descriptor(trace_descriptor),.trace_frozen(trace_frozen),.trace_count(trace_count),
        .read_index(trace_index),.read_record(trace_record));
    dbg_dma u_dma (
        .clk(clk),.rst(rst),.request_valid(dma_valid),.request_ready(dma_ready),
        .request_write(dma_write),.request_bist(1'b0),.request_address(dma_address),.request_size(dma_size),
        .request_count(dma_count),.request_data(dma_data),.response_valid(dma_response),
        .response_ready(state==DMA_WAIT || state==VERIFY_WAIT || state==BSS_WAIT),
        .response_status(dma_status),.response_completed(dma_completed),.response_address(dma_error_address),
        .response_unknown(dma_unknown),.response_data(dma_result),.bus(dma_bus),.bus_response(bus_response));
    hw_bist u_bist (
        .clk(clk),.rst(rst),.start(bist_start),.abort_test(abort_pending),.cpu_safe(cpu.stopped && !cpu.reset_held),
        .test_id(bist_id),.address(bist_address),.bytes(bist_bytes),.ready(bist_ready),.active(bist_active),.done(bist_done),
        .status(bist_status),.phase(bist_phase),.completed(bist_completed),.first_address(bist_first),
        .expected(bist_expected),.observed(bist_observed),.alu_test(bist_alu_test),.alu_op(bist_alu_op),
        .alu_a(bist_a),.alu_b(bist_b),.alu_result(cpu.alu_result),.bus(bist_bus),.bus_response(bus_response));
    task automatic respond(input logic [15:0] status,length,input logic [383:0] payload);
        result_status<=status; result_length<=length; reply_meta<=payload; reply_kind<=REPLY_META; reply_busy<=1; reply_index<=0;
    endtask
    task automatic finish_operation(input logic [15:0] status);
        operation_status<=status;
        operation_state<=status==DBG_ST_OK ? DBG_OPST_DONE : DBG_OPST_FAILED;
        operation_active<=0; abort_pending<=0; loading<=0;
        image_valid<=status==DBG_ST_OK; image_modified<=0; state<=IDLE;
        generation<=generation+1'b1;
    endtask
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE; opcode<=0; timer<=0; generation<=0; load_id<=0;
            image_bytes<=0; expected_crc<=0; bss_address<=0; bss_bytes<=0; received_bytes<=0;
            image_valid<=0; image_modified<=0; loading<=0; operation_active<=0; abort_pending<=0;
            verify_offset<=0; crc<=32'hffffffff; observed_crc<=0; zero_address<=0; zero_remaining<=0;
            crc_index<=0; verify_bytes<=0; operation_id<=0; operation_state<=DBG_OPST_IDLE;
            operation_status<=DBG_ST_OK; operation_completed<=0; operation_address<=0;
            previous_stopped<=1; previous_reset<=1;
            reply_reg_start<=0; reply_reg_word<=0; reply_trace_generation<=0; register_expected<=0;
            dma_write<=0; dma_address<=0; dma_size<=0; dma_count<=0; dma_source<=INPUT_ZERO; saved_valid<=0; memory_bytes<=0;
            result_valid<=0; result_status<=DBG_ST_OK; result_length<=0; reply_meta<=0;
            reply_busy<=0; reply_kind<=REPLY_META; reply_index<=0; reply_counter_offset<=0;
            debug_reset_hold<=1; debug_control<='0; halt_reason<=DBG_HALT_RESET;
            capture_counters<=0; freeze_trace<=0; arm_trace<=0;
            trace_index<=0;
            bist_start<=0; bist_id<=0; bist_address<=0; bist_bytes<=0; operation_kind<=0;
            fault_armed<=0; fault_active<=0; fault_fired<=0; fault_restore_pending<=0; fault_restored<=0;
            fault_state<=0; arm_id<=0; fault_address<=0; fault_mask<=0; fault_saved<=0; fault_original<=0;
            fault_observed<=0; fault_restored_value<=0; fault_triggers<=0; fault_operation<=0;
            fault_detection<=DBG_ST_NOT_FOUND; fault_cleanup<=DBG_ST_NOT_FOUND;
            name_index<=0; utf8_needed<=0; utf8_min<=8'h80; utf8_max<=8'hbf;
        end else begin
            debug_control.halt<=0; debug_control.resume<=0; debug_control.step<=0;
            debug_control.bypass_break<=0; debug_control.reg_we<=0;
            capture_counters<=0; freeze_trace<=0; arm_trace<=0;
            bist_start<=0;
            debug_control.alu_test<=bist_alu_test; debug_control.alu_op<=bist_alu_op;
            debug_control.alu_a<=bist_a; debug_control.alu_b<=bist_b;
            previous_stopped<=cpu.stopped; previous_reset<=cpu.reset_held;
            if((cpu.stopped && !previous_stopped)||(cpu.reset_held && !previous_reset)) generation<=generation+1'b1;
            if(result_valid && result_ready) result_valid<=0;
            if(reply_busy) begin
                if((reply_kind==REPLY_REGISTERS && (!cpu.stopped || cpu.reset_held)) ||
                   (reply_kind==REPLY_TRACE && (!trace_frozen || trace_generation!=reply_trace_generation))) begin
                    result_status<=reply_kind==REPLY_TRACE ? DBG_ST_NOT_FOUND : DBG_ST_BAD_STATE;
                    result_length<=0; reply_meta<=0; reply_kind<=REPLY_META; reply_index<=0;
                end else begin
                    if(reply_index==8'(DBG_MAX_PAYLOAD-1)) begin reply_busy<=0; result_valid<=1; end
                    else reply_index<=reply_index+1'b1;
                    if(reply_kind==REPLY_REGISTERS && reply_index>=8 && {8'd0,reply_index}<result_length) begin
                        if(reply_reg_byte==0) reply_reg_word<=cpu.reg_rdata;
                        // Prefetch the next register while the latched current word drains.
                        if(reply_reg_byte==1) debug_control.reg_addr<=reply_reg_start+reply_reg_number+5'd1;
                    end
                    // One synchronous trace read of lead time; byte 31 still uses the old word.
                    if(reply_kind==REPLY_TRACE && reply_index>=12 && reply_trace_byte==30 &&
                       {8'd0,reply_index}+16'd2<result_length) trace_index<=trace_index+1'b1;
                end
            end
            if(cpu.reset_held && !previous_reset) begin
                fault_armed<=0; fault_active<=0; fault_restore_pending<=0;
                if(fault_state!=0 && !fault_restored) begin fault_state<=5; fault_cleanup<=DBG_ST_ABORTED; end
            end
            if(bus_response.fault_fired && fault_active) begin
                fault_active<=0; fault_fired<=1; fault_state<=3; fault_triggers<=fault_triggers+1'b1;
                fault_original<=bus_response.fault_original; fault_observed<=bus_response.fault_observed;
            end
            if(active_session==0 && (loading || operation_active)) abort_pending<=1;
            if(active_session==0 && (fault_armed || fault_active)) begin
                fault_armed<=0; fault_active<=0; fault_state<=5; fault_cleanup<=DBG_ST_ABORTED;
            end
            if(loading && abort_pending && state==IDLE) begin
                loading<=0; abort_pending<=0; image_valid<=0;
                operation_state<=DBG_OPST_FAILED; operation_status<=DBG_ST_ABORTED;
            end
            if(execute_valid && execute_ready) begin
                if(operation_active) begin
                    if((operation_kind==1 && execute_request.opcode==DBG_OP_LOAD_ABORT && execute_request.length==4 &&
                        execute_request.payload[0+:32]==load_id) ||
                       (execute_request.opcode==DBG_OP_CPU_RESET && execute_request.length==0)) begin
                        abort_pending<=1; debug_reset_hold<=1; operation_state<=DBG_OPST_ABORTING;
                        respond(DBG_ST_ACCEPTED,8,{{320{1'b0}},operation_id});
                    end else if(execute_request.opcode==DBG_OP_BIST_ABORT && operation_kind!=1 &&
                                execute_request.length==8 && execute_request.payload[0+:64]==operation_id) begin
                        abort_pending<=1; operation_state<=DBG_OPST_ABORTING;
                        respond(DBG_ST_ACCEPTED,8,{{320{1'b0}},operation_id});
                    end else respond(DBG_ST_BUSY,0,'0);
                end else begin
                    opcode<=execute_request.opcode; timer<=0;
                    case(execute_request.opcode)
                        DBG_OP_HALT,DBG_OP_RESUME,DBG_OP_STEP,DBG_OP_CPU_RESET: begin
                            if(execute_request.length!=0) respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else if(execute_request.opcode==DBG_OP_CPU_RESET) begin
                                debug_reset_hold<=1; loading<=0; abort_pending<=0;
                                if(loading) begin operation_state<=DBG_OPST_FAILED; operation_status<=DBG_ST_ABORTED; end
                                halt_reason<=DBG_HALT_RESET; timer<=3; state<=RESET_WAIT;
                            end else if(execute_request.opcode==DBG_OP_HALT) begin
                                if(cpu.stopped) respond(DBG_ST_OK,36,384'(status_payload));
                                else begin debug_control.halt<=1; halt_reason<=DBG_HALT_REQUEST; state<=HALT_WAIT; end
                            end else if(!cpu.stopped || cpu.reset_held || cpu_terminal || !bus_response.cpu_owns)
                                respond(DBG_ST_BAD_STATE,0,'0);
                            else if(fault_armed || fault_active || fault_restore_pending) respond(DBG_ST_BAD_STATE,0,'0);
                            else if(!image_valid) respond(DBG_ST_IMAGE_INVALID,0,'0);
                            else begin
                                debug_control.bypass_break<=execute_request.opcode==DBG_OP_STEP || cpu.breakpoint;
                                debug_control.step<=execute_request.opcode==DBG_OP_STEP;
                                debug_control.resume<=execute_request.opcode==DBG_OP_RESUME;
                                halt_reason<=execute_request.opcode==DBG_OP_STEP ? DBG_HALT_STEP : DBG_HALT_NONE;
                                timer<=2;
                                state<=execute_request.opcode==DBG_OP_STEP ? STEP_ADMIT : RESUME_WAIT;
                            end
                        end
                        DBG_OP_RUN,DBG_OP_RESTART: begin
                            if(execute_request.length!=4) respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else if(!image_valid || execute_request.payload[0+:32]!=load_id) respond(DBG_ST_IMAGE_INVALID,0,'0);
                            else if(!cpu.stopped || !bus_response.cpu_owns) respond(DBG_ST_BAD_STATE,0,'0);
                            else if(fault_armed || fault_active || fault_restore_pending) respond(DBG_ST_BAD_STATE,0,'0);
                            else begin
                                debug_reset_hold<=1; timer<=3; state<=RESET_WAIT;
                                halt_reason<=DBG_HALT_NONE;
                            end
                        end
                        DBG_OP_REG_READ: begin
                            if(execute_request.length!=4 || execute_request.payload[16+:16]!=0 ||
                               execute_request.payload[0+:8]>=32 || execute_request.payload[8+:8]==0 ||
                               {1'b0,execute_request.payload[0+:8]}+{1'b0,execute_request.payload[8+:8]}>9'd32)
                                respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else if(!cpu.stopped || cpu.reset_held) respond(DBG_ST_BAD_STATE,0,'0);
                            else begin
                                reply_reg_start<=execute_request.payload[0+:5]; debug_control.reg_addr<=execute_request.payload[0+:5];
                                generation<=generation+1'b1;
                                respond(DBG_ST_OK,16'd8+{6'd0,execute_request.payload[8+:8],2'd0},'0);
                                reply_kind<=REPLY_REGISTERS; reply_meta[0+:32]<=generation+1'b1;
                                reply_meta[32+:8]<=execute_request.payload[0+:8]; reply_meta[40+:8]<=execute_request.payload[8+:8];
                            end
                        end
                        DBG_OP_REG_WRITE: begin
                            if(execute_request.length!=8 || execute_request.payload[0+:8]==0 ||
                               execute_request.payload[0+:8]>=32 || execute_request.payload[8+:24]!=0)
                                respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else if(!cpu.stopped || cpu.reset_held) respond(DBG_ST_BAD_STATE,0,'0);
                            else begin
                                debug_control.reg_addr<=execute_request.payload[0+:5];
                                debug_control.reg_wdata<=execute_request.payload[32+:32]; debug_control.reg_we<=1;
                                register_expected<=execute_request.payload[32+:32]; state<=REG_WRITE_WAIT;
                            end
                        end
                        DBG_OP_MEM_READ,DBG_OP_MEM_WRITE: begin
                            if(execute_request.length<8 || execute_request.payload[40+:8]!=0 ||
                               (execute_request.opcode==DBG_OP_MEM_READ && execute_request.length!=8) ||
                               (execute_request.opcode==DBG_OP_MEM_WRITE &&
                                {3'd0,execute_request.length}!=19'd8+request_bytes) ||
                               request_bytes==0 || request_bytes>19'(DBG_MAX_MEM_DATA) ||
                               (execute_request.payload[32+:8]!=1 && execute_request.payload[32+:8]!=2 && execute_request.payload[32+:8]!=4))
                                respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else if((execute_request.payload[32+:8]==2 && execute_request.payload[0]) ||
                                    (execute_request.payload[32+:8]==4 && execute_request.payload[0+:2]!=0))
                                respond(DBG_ST_ALIGNMENT,0,'0);
                            else if(request_end>33'h10000) respond(DBG_ST_BAD_ADDRESS,0,'0);
                            else if(!cpu.stopped) respond(DBG_ST_BAD_STATE,0,'0);
                            else begin
                                dma_address<=execute_request.payload[0+:32]; dma_size<=execute_request.payload[32+:8];
                                dma_count<=execute_request.payload[48+:16]; dma_write<=execute_request.opcode==DBG_OP_MEM_WRITE;
                                dma_source<=INPUT_MEM;
                                saved_valid<=image_valid; memory_bytes<=16'(request_bytes);
                                state<=DMA_START;
                            end
                        end
                        DBG_OP_BREAK_SET,DBG_OP_BREAK_CLEAR: begin
                            if((execute_request.opcode==DBG_OP_BREAK_SET &&
                                (execute_request.length!=8 || execute_request.payload[8+:8]>1 || execute_request.payload[16+:16]!=0)) ||
                               (execute_request.opcode==DBG_OP_BREAK_CLEAR &&
                                (execute_request.length!=4 || execute_request.payload[8+:24]!=0)) ||
                               execute_request.payload[0+:8]>=2)
                                respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else if(!cpu.stopped) respond(DBG_ST_BAD_STATE,0,'0);
                            else if(execute_request.opcode==DBG_OP_BREAK_SET && execute_request.payload[32+:2]!=0)
                                respond(DBG_ST_ALIGNMENT,0,'0);
                            else if(execute_request.opcode==DBG_OP_BREAK_SET && execute_request.payload[48+:16]!=0)
                                respond(DBG_ST_BAD_ADDRESS,0,'0);
                            else begin
                                debug_control.breakpoint_enable[execute_request.payload[0]]<=execute_request.opcode==DBG_OP_BREAK_SET && execute_request.payload[8];
                                if(execute_request.payload[0]) debug_control.breakpoint1<=execute_request.payload[32+:32];
                                else debug_control.breakpoint0<=execute_request.payload[32+:32];
                                generation<=generation+1'b1; respond(DBG_ST_OK,0,'0);
                            end
                        end
                        DBG_OP_BREAK_LIST: begin
                            if(execute_request.length!=0) respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else begin
                                respond(DBG_ST_OK,28,'0);
                                reply_meta[0+:32]<=generation; reply_meta[32+:32]<=cpu.next_pc;
                                reply_meta[64+:8]<=cpu.breakpoint ? (cpu.next_pc==debug_control.breakpoint0 ? 8'd0 : 8'd1) : 8'hff;
                                reply_meta[72+:8]<=2;
                                reply_meta[96+:8]<={7'd0,debug_control.breakpoint_enable[0]};
                                reply_meta[128+:32]<=debug_control.breakpoint0;
                                reply_meta[160+:8]<={7'd0,debug_control.breakpoint_enable[1]};
                                reply_meta[192+:32]<=debug_control.breakpoint1;
                            end
                        end
                        DBG_OP_COUNTERS_LATCH,DBG_OP_TRACE_FREEZE,DBG_OP_TRACE_ARM: begin
                            if((execute_request.opcode==DBG_OP_TRACE_ARM &&
                                (execute_request.length!=4 || execute_request.payload[0+:32]!=1)) ||
                               (execute_request.opcode!=DBG_OP_TRACE_ARM && execute_request.length!=0))
                                respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else begin
                                capture_counters<=execute_request.opcode==DBG_OP_COUNTERS_LATCH;
                                freeze_trace<=execute_request.opcode==DBG_OP_TRACE_FREEZE;
                                arm_trace<=execute_request.opcode==DBG_OP_TRACE_ARM;
                                timer<=2; state<=OBSERVE_WAIT;
                            end
                        end
                        DBG_OP_COUNTERS_READ: begin
                            if(execute_request.length!=12 || execute_request.payload[80+:16]!=0 ||
                               execute_request.payload[64+:16]==0 || execute_request.payload[64+:16]>64)
                                respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else if(counter_generation==0 || execute_request.payload[0+:32]!=counter_generation)
                                respond(DBG_ST_NOT_FOUND,0,'0);
                            else if({1'b0,execute_request.payload[32+:32]}+{17'd0,execute_request.payload[64+:16]}>64)
                                respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else begin
                                respond(DBG_ST_OK,16'd12+execute_request.payload[64+:16],'0);
                                reply_meta[0+:80]<=execute_request.payload[0+:80];
                                reply_kind<=REPLY_COUNTER_SLICE; reply_counter_offset<=execute_request.payload[32+:6];
                                reply_meta[80+:16]<=1;
                            end
                        end
                        DBG_OP_TRACE_READ: begin
                            if(execute_request.length!=12 || execute_request.payload[80+:16]!=0 ||
                               execute_request.payload[64+:16]==0 || execute_request.payload[64+:16]>6)
                                respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else if(!trace_frozen || execute_request.payload[0+:32]!=trace_generation)
                                respond(DBG_ST_NOT_FOUND,0,'0);
                            else if({1'b0,execute_request.payload[32+:32]}+{17'd0,execute_request.payload[64+:16]}>{24'd0,trace_count})
                                respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else begin
                                trace_index<=execute_request.payload[32+:8]; reply_trace_generation<=trace_generation;
                                respond(DBG_ST_OK,16'd12+execute_request.payload[64+:16]*16'd32,'0);
                                reply_kind<=REPLY_TRACE; reply_meta[0+:80]<=execute_request.payload[0+:80]; reply_meta[80+:16]<=32;
                            end
                        end
                        DBG_OP_LOAD_BEGIN: begin
                            if(execute_request.length<40 || execute_request.payload[288+:16]!=0 ||
                               execute_request.payload[272+:16]!=1 || execute_request.payload[256+:16]!=1 ||
                               execute_request.payload[304+:16]>16'(DBG_MAX_NAME) ||
                               execute_request.length!=16'd40+execute_request.payload[304+:16])
                                respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else if(!cpu.stopped) respond(DBG_ST_BAD_STATE,0,'0);
                            else if(fault_armed || fault_active || fault_restore_pending) respond(DBG_ST_BAD_STATE,0,'0);
                            else if(execute_request.payload[0+:32]!=0 || execute_request.payload[32+:32]!=0 ||
                                    execute_request.payload[64+:32]==0 || execute_request.payload[64+:32]>32'hd000 ||
                                    execute_request.payload[128+:32]<execute_request.payload[64+:32] ||
                                    {1'd0,execute_request.payload[128+:32]}+{1'd0,execute_request.payload[160+:32]}>33'hd000 ||
                                    execute_request.payload[192+:32]!=32'he000 || execute_request.payload[224+:32]!=32'h10000)
                                respond(DBG_ST_BAD_ADDRESS,0,'0);
                            else if(execute_request.payload[128+:2]!=0 || execute_request.payload[160+:2]!=0)
                                respond(DBG_ST_ALIGNMENT,0,'0);
                            else begin
                                name_index<=0; utf8_needed<=0; utf8_min<=8'h80; utf8_max<=8'hbf; state<=LOAD_NAME;
                            end
                        end
                        DBG_OP_LOAD_CHUNK: begin
                            if(execute_request.length<13 || execute_request.payload[64+:16]==0 ||
                               execute_request.payload[64+:16]>16'(DBG_MAX_CHUNK) ||
                               execute_request.payload[80+:16]!=0 ||
                               execute_request.length!=16'd12+execute_request.payload[64+:16])
                                respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else if(!loading || execute_request.payload[0+:32]!=load_id) respond(DBG_ST_NOT_FOUND,0,'0);
                            else if(execute_request.payload[32+:32]!=received_bytes ||
                                    {1'd0,received_bytes}+{17'd0,execute_request.payload[64+:16]}>{1'd0,image_bytes})
                                respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else begin
                                dma_address<=received_bytes; dma_size<=1; dma_count<=execute_request.payload[64+:16]; dma_write<=1;
                                dma_source<=INPUT_LOAD;
                                state<=DMA_START;
                            end
                        end
                        DBG_OP_LOAD_COMMIT,DBG_OP_LOAD_ABORT: begin
                            if(execute_request.length!=4) respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else if(!loading || execute_request.payload[0+:32]!=load_id) respond(DBG_ST_NOT_FOUND,0,'0);
                            else if(execute_request.opcode==DBG_OP_LOAD_ABORT) begin
                                loading<=0; image_valid<=0; operation_state<=DBG_OPST_FAILED; operation_status<=DBG_ST_ABORTED;
                                respond(DBG_ST_OK,0,'0);
                            end else if(received_bytes!=image_bytes) respond(DBG_ST_IMAGE_INVALID,0,'0);
                            else begin
                                loading<=0; operation_active<=1; abort_pending<=0; operation_state<=DBG_OPST_VERIFYING;
                                operation_kind<=1;
                                operation_id<=operation_id+1'b1; operation_status<=DBG_ST_ACCEPTED;
                                verify_offset<=0; crc<=32'hffffffff; operation_completed<=0; operation_address<=0;
                                state<=VERIFY_START;
                                respond(DBG_ST_ACCEPTED,8,'0); reply_meta[0+:64]<=operation_id+1'b1;
                            end
                        end
                        DBG_OP_DIAG_RESULT: begin
                            if(execute_request.length!=8) respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else if(execute_request.payload[0+:64]!=operation_id || operation_id==0) respond(DBG_ST_NOT_FOUND,0,'0);
                            else begin
                                respond(DBG_ST_OK,operation_kind==1 ? 16'd36 : 16'd44,'0); reply_meta[0+:64]<=operation_id;
                                reply_meta[64+:8]<=operation_kind; reply_meta[72+:8]<=operation_state;
                                reply_meta[80+:16]<=operation_status; reply_meta[96+:32]<=operation_completed;
                                if(operation_kind==1) begin
                                    reply_meta[128+:32]<=expected_crc; reply_meta[160+:32]<=observed_crc;
                                    reply_meta[192+:32]<=operation_address; reply_meta[224+:32]<=load_id;
                                end else begin
                                    reply_meta[128+:32]<=bist_first; reply_meta[160+:32]<=bist_expected;
                                    reply_meta[192+:32]<=bist_observed;
                                    reply_meta[224+:32]<=operation_status==DBG_ST_VERIFY_FAILED ? 32'd1 : 32'd0;
                                    reply_meta[256+:32]<=bist_address; reply_meta[288+:32]<=bist_bytes;
                                    reply_meta[320+:8]<=bist_phase;
                                end
                            end
                        end
                        DBG_OP_BIST_START: begin
                            if(execute_request.length!=12 || execute_request.payload[8+:24]!=0 ||
                               (execute_request.payload[0+:8]!=1 && execute_request.payload[0+:8]!=2))
                                respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else if(!cpu.stopped || cpu.reset_held || !bus_response.cpu_owns || fault_armed)
                                respond(DBG_ST_BAD_STATE,0,'0);
                            else if(execute_request.payload[0+:8]==2 &&
                                    (execute_request.payload[32+:32]!=0 || execute_request.payload[64+:32]!=0))
                                respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else if(execute_request.payload[0+:8]==1 &&
                                    (execute_request.payload[32+:2]!=0 || execute_request.payload[64+:2]!=0))
                                respond(DBG_ST_ALIGNMENT,0,'0);
                            else if(execute_request.payload[0+:8]==1 &&
                                    (execute_request.payload[64+:32]==0 || execute_request.payload[32+:32]<32'hd000 ||
                                     {1'b0,execute_request.payload[32+:32]}+{1'b0,execute_request.payload[64+:32]}>33'he000))
                                respond(DBG_ST_BAD_ADDRESS,0,'0);
                            else begin
                                bist_id<=execute_request.payload[0+:8]; bist_address<=execute_request.payload[32+:32];
                                bist_bytes<=execute_request.payload[64+:32]; bist_start<=1; state<=BIST_WAIT;
                                operation_active<=1; abort_pending<=0; operation_state<=DBG_OPST_BIST;
                                operation_kind<=execute_request.payload[0+:8]+1'b1; operation_status<=DBG_ST_ACCEPTED;
                                operation_id<=operation_id+1'b1; operation_completed<=0;
                                if(fault_active) fault_operation<=operation_id+1'b1;
                                respond(DBG_ST_ACCEPTED,8,'0); reply_meta[0+:64]<=operation_id+1'b1;
                            end
                        end
                        DBG_OP_INJECT_ARM: begin
                            if(execute_request.length!=16 || execute_request.payload[0+:8]!=1 ||
                               execute_request.payload[8+:8]!=1 || execute_request.payload[16+:16]!=1 ||
                               execute_request.payload[64+:32]==0 || execute_request.payload[96+:32]!=0)
                                respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else if(!cpu.stopped || cpu.reset_held || fault_armed || fault_restore_pending)
                                respond(DBG_ST_BAD_STATE,0,'0);
                            else if(execute_request.payload[32+:2]!=0) respond(DBG_ST_ALIGNMENT,0,'0);
                            else if(execute_request.payload[32+:32]<32'hd000 || execute_request.payload[32+:32]>32'hdffc)
                                respond(DBG_ST_BAD_ADDRESS,0,'0);
                            else begin
                                arm_id<=arm_id==32'hffffffff ? 1 : arm_id+1'b1;
                                fault_address<=execute_request.payload[32+:32]; fault_mask<=execute_request.payload[64+:32];
                                fault_armed<=1; fault_active<=0; fault_fired<=0; fault_restored<=0;
                                fault_state<=1; fault_triggers<=0; fault_operation<=0; fault_detection<=DBG_ST_NOT_FOUND;
                                fault_cleanup<=DBG_ST_NOT_FOUND; fault_saved<=0; fault_original<=0; fault_observed<=0; fault_restored_value<=0;
                                respond(DBG_ST_OK,4,'0); reply_meta[0+:32]<=arm_id==32'hffffffff ? 1 : arm_id+1'b1;
                            end
                        end
                        DBG_OP_INJECT_FIRE,DBG_OP_INJECT_CLEAR,DBG_OP_INJECT_RESULT: begin
                            if(execute_request.length!=4) respond(DBG_ST_BAD_ARGUMENT,0,'0);
                            else if(arm_id==0 || (execute_request.payload[0+:32]!=arm_id &&
                                    !(execute_request.opcode==DBG_OP_INJECT_RESULT && execute_request.payload[0+:32]==0)))
                                respond(DBG_ST_NOT_FOUND,0,'0);
                            else if(execute_request.opcode==DBG_OP_INJECT_RESULT) begin
                                respond(DBG_ST_OK,48,'0); reply_meta[0+:32]<=arm_id;
                                reply_meta[32+:8]<=1; reply_meta[40+:8]<=fault_state;
                                reply_meta[48+:16]<={11'd0,fault_restored,fault_restore_pending,fault_fired,fault_active,fault_armed};
                                reply_meta[64+:32]<=fault_address; reply_meta[96+:32]<=fault_mask;
                                reply_meta[128+:32]<=fault_saved; reply_meta[160+:32]<=fault_original;
                                reply_meta[192+:32]<=fault_observed; reply_meta[224+:32]<=fault_triggers;
                                reply_meta[256+:64]<=fault_operation; reply_meta[320+:16]<=fault_detection;
                                reply_meta[336+:16]<=fault_cleanup; reply_meta[352+:32]<=fault_restored_value;
                            end else if(!cpu.stopped || cpu.reset_held) respond(DBG_ST_BAD_STATE,0,'0);
                            else if(execute_request.opcode==DBG_OP_INJECT_FIRE && !fault_armed) respond(DBG_ST_BAD_STATE,0,'0);
                            else if(execute_request.opcode==DBG_OP_INJECT_CLEAR && !fault_restore_pending) begin
                                fault_armed<=0; fault_active<=0; fault_state<=0; respond(DBG_ST_OK,0,'0);
                            end else begin
                                fault_active<=0; fault_armed<=0;
                                dma_address<=fault_address; dma_size<=4; dma_count<=1;
                                dma_write<=execute_request.opcode==DBG_OP_INJECT_CLEAR;
                                dma_source<=execute_request.opcode==DBG_OP_INJECT_CLEAR ? INPUT_RESTORE : INPUT_ZERO; state<=DMA_START;
                            end
                        end
                        default: respond(DBG_ST_UNSUPPORTED,0,'0);
                    endcase
                end
            end
            case(state)
                LOAD_NAME: begin
                    if(name_index==6'(held_payload[304+:16])) begin
                        state<=IDLE;
                        if(utf8_needed!=0) respond(DBG_ST_BAD_ARGUMENT,0,'0);
                        else begin
                            load_id<=load_id==32'hffffffff ? 1 : load_id+1'b1;
                            image_bytes<=held_payload[64+:32]; expected_crc<=held_payload[96+:32];
                            bss_address<=held_payload[128+:32]; bss_bytes<=held_payload[160+:32];
                            received_bytes<=0; loading<=1; image_valid<=0; image_modified<=0; abort_pending<=0;
                            operation_state<=DBG_OPST_LOADING; operation_status<=DBG_ST_OK; debug_reset_hold<=1;
                            generation<=generation+1'b1;
                            respond(DBG_ST_OK,4,'0); reply_meta[0+:32]<=load_id==32'hffffffff ? 1 : load_id+1'b1;
                        end
                    end else begin
                        name_index<=name_index+1'b1;
                        if(utf8_needed!=0) begin
                            if(name_byte<utf8_min || name_byte>utf8_max) begin respond(DBG_ST_BAD_ARGUMENT,0,'0); state<=IDLE; end
                            else begin utf8_needed<=utf8_needed-1'b1; utf8_min<=8'h80; utf8_max<=8'hbf; end
                        end else if(name_byte<8'h80) begin end
                        else if(name_byte>=8'hc2 && name_byte<=8'hdf) utf8_needed<=1;
                        else if(name_byte>=8'he0 && name_byte<=8'hef) begin
                            utf8_needed<=2; utf8_min<=name_byte==8'he0 ? 8'ha0 : 8'h80;
                            utf8_max<=name_byte==8'hed ? 8'h9f : 8'hbf;
                        end else if(name_byte>=8'hf0 && name_byte<=8'hf4) begin
                            utf8_needed<=3; utf8_min<=name_byte==8'hf0 ? 8'h90 : 8'h80;
                            utf8_max<=name_byte==8'hf4 ? 8'h8f : 8'hbf;
                        end else begin respond(DBG_ST_BAD_ARGUMENT,0,'0); state<=IDLE; end
                    end
                end
                BIST_WAIT: begin
                    operation_completed<=bist_completed;
                    if(bist_done) begin
                        operation_status<=bist_status; operation_state<=bist_status==DBG_ST_OK ? DBG_OPST_DONE : DBG_OPST_FAILED;
                        operation_completed<=bist_completed; operation_active<=0; abort_pending<=0; state<=IDLE;
                        fault_active<=0;
                        if(fault_operation==operation_id && fault_fired)
                            fault_detection<=bist_status==DBG_ST_VERIFY_FAILED && bist_first==fault_address &&
                                bist_expected==fault_original && bist_observed==fault_observed &&
                                bist_observed==(bist_expected^fault_mask) && fault_triggers==1 ? DBG_ST_OK : DBG_ST_VERIFY_FAILED;
                    end
                end
                OBSERVE_WAIT: if(timer!=0) timer<=timer-1'b1;
                    else begin
                        if(opcode==DBG_OP_COUNTERS_LATCH) begin respond(DBG_ST_OK,64,'0); reply_kind<=REPLY_COUNTERS; end
                        else if(opcode==DBG_OP_TRACE_FREEZE) respond(DBG_ST_OK,48,trace_descriptor);
                        else begin respond(DBG_ST_OK,4,'0); reply_meta[0+:32]<=trace_generation; end
                        state<=IDLE;
                    end
                HALT_WAIT: begin
                    if(cpu.stopped) begin respond(DBG_ST_OK,36,384'(status_payload)); state<=IDLE; end
                    else if(timer==16'hffff) begin respond(DBG_ST_OUTCOME_UNKNOWN,0,'0); state<=IDLE; end
                    else timer<=timer+1'b1;
                end
                STEP_ADMIT: begin
                    if(timer==0) state<=STEP_WAIT; else timer<=timer-1'b1;
                end
                STEP_WAIT: begin
                    if(cpu.stopped) begin respond(DBG_ST_OK,36,384'(status_payload)); state<=IDLE; end
                    else if(timer==16'hffff) begin respond(DBG_ST_OUTCOME_UNKNOWN,0,'0); state<=IDLE; end
                    else timer<=timer+1'b1;
                end
                RESUME_WAIT: if(timer==0) begin respond(DBG_ST_OK,36,384'(status_payload)); state<=IDLE; end
                             else timer<=timer-1'b1;
                RESET_WAIT: if(timer!=0) timer<=timer-1'b1;
                    else if(opcode==DBG_OP_CPU_RESET) begin respond(DBG_ST_OK,36,384'(status_payload)); state<=IDLE; end
                    else begin debug_reset_hold<=0; timer<=2; state<=RUN_PRIME; end
                RUN_PRIME: if(timer!=0) timer<=timer-1'b1;
                    else begin debug_control.resume<=1; debug_control.bypass_break<=0; timer<=2; state<=RESUME_WAIT; end
                REG_WRITE_WAIT: state<=REG_WRITE_CHECK;
                REG_WRITE_CHECK: begin
                    if(!cpu.stopped || cpu.reset_held) begin
                        image_valid<=0; image_modified<=1;
                        respond(DBG_ST_OUTCOME_UNKNOWN,0,'0);
                    end else if(cpu.reg_rdata!=register_expected) begin
                        image_valid<=0; image_modified<=1;
                        respond(DBG_ST_VERIFY_FAILED,0,'0);
                    end
                    else begin
                        generation<=generation+1'b1; image_modified<=1;
                        respond(DBG_ST_OK,8,'0); reply_meta[0+:32]<=generation+1'b1;
                        reply_meta[32+:32]<=cpu.reg_rdata;
                    end
                    state<=IDLE;
                end
                DMA_START: if(dma_ready) begin
                    if(opcode==DBG_OP_MEM_WRITE) image_valid<=0;
                    state<=DMA_WAIT;
                end
                DMA_WAIT: if(dma_response) begin
                    state<=IDLE;
                    if(opcode==DBG_OP_INJECT_FIRE || opcode==DBG_OP_INJECT_CLEAR) begin
                        respond(dma_status,dma_status==DBG_ST_OK ? 16'd4 : 16'd0,'0);
                        reply_meta[0+:32]<=arm_id;
                        if(cpu.reset_held || active_session==0) begin
                            respond(DBG_ST_BAD_STATE,0,'0); fault_active<=0; fault_restore_pending<=0;
                            fault_state<=5; fault_cleanup<=DBG_ST_ABORTED;
                        end else if(dma_status!=DBG_ST_OK) begin fault_state<=6; fault_cleanup<=dma_status; end
                        else if(opcode==DBG_OP_INJECT_FIRE) begin
                            fault_saved<=dma_result[0+:32]; fault_active<=1; fault_restore_pending<=1; fault_state<=2;
                        end else begin
                            fault_restore_pending<=0; fault_restored<=1; fault_state<=4;
                            fault_cleanup<=DBG_ST_OK; fault_restored_value<=dma_result[0+:32];
                        end
                    end else if(opcode==DBG_OP_LOAD_CHUNK) begin
                        if(dma_status==DBG_ST_OK) begin
                            received_bytes<=received_bytes+{16'd0,dma_completed};
                            respond(DBG_ST_OK,8,'0); reply_meta[0+:32]<=load_id;
                            reply_meta[32+:32]<=received_bytes+{16'd0,dma_completed};
                        end else begin
                            loading<=0; image_valid<=0; operation_state<=DBG_OPST_FAILED; operation_status<=dma_status;
                            respond(dma_status,0,'0);
                        end
                    end else begin
                        respond(dma_status,opcode==DBG_OP_MEM_READ && dma_status==DBG_ST_OK ?
                                16'd8+memory_bytes : 16'd8,'0);
                        if(opcode==DBG_OP_MEM_READ) begin
                            reply_meta[0+:32]<=generation; reply_meta[32+:16]<=dma_completed;
                            reply_meta[48+:8]<=dma_size;
                            if(dma_status==DBG_ST_OK) reply_kind<=REPLY_MEMORY;
                        end else begin
                            reply_meta[0+:16]<=dma_completed; reply_meta[16+:8]<=dma_size;
                            reply_meta[24+:8]<={7'd0,dma_unknown}; reply_meta[32+:32]<=dma_error_address;
                            if(dma_status==DBG_ST_OK) begin image_valid<=saved_valid; image_modified<=1; generation<=generation+1'b1; end
                        end
                    end
                end
                VERIFY_START: begin
                    dma_address<=verify_offset; dma_write<=0; dma_source<=INPUT_ZERO; verify_bytes<=next_verify_bytes;
                    dma_size<=next_verify_bytes[1:0]==0 ? 8'd4 : 8'd1;
                    dma_count<=next_verify_bytes[1:0]==0 ? next_verify_bytes>>2 : next_verify_bytes;
                    state<=VERIFY_ISSUE;
                end
                VERIFY_ISSUE: begin
                    if(abort_pending) finish_operation(DBG_ST_ABORTED);
                    else if(dma_ready) state<=VERIFY_WAIT;
                end
                VERIFY_WAIT: begin
                    if(dma_response) begin
                        if(abort_pending) finish_operation(DBG_ST_ABORTED);
                        else if(dma_status!=DBG_ST_OK) begin operation_address<=dma_error_address; finish_operation(dma_status); end
                        else begin crc_index<=0; state<=VERIFY_CRC; end
                    end
                end
                VERIFY_CRC: begin
                    if(abort_pending) finish_operation(DBG_ST_ABORTED);
                    else begin
                        crc<=crc_next;
                        if(crc_index+1'b1==verify_bytes) begin
                            verify_offset<=verify_offset+{16'd0,verify_bytes}; operation_completed<=verify_offset+{16'd0,verify_bytes};
                            if(verify_offset+{16'd0,verify_bytes}==image_bytes) begin
                                observed_crc<=~crc_next;
                                if(~crc_next!=expected_crc) finish_operation(DBG_ST_VERIFY_FAILED);
                                else if(bss_bytes==0) finish_operation(DBG_ST_OK);
                                else begin zero_address<=bss_address; zero_remaining<=bss_bytes; state<=BSS_START; end
                            end else state<=VERIFY_START;
                        end else crc_index<=crc_index+1'b1;
                    end
                end
                BSS_START: begin
                    dma_address<=zero_address; dma_write<=1; dma_source<=INPUT_ZERO; dma_size<=4;
                    dma_count<=zero_remaining>DBG_MAX_MEM_DATA ? 16'(DBG_MAX_MEM_DATA/4) : 16'(zero_remaining>>2);
                    state<=BSS_ISSUE;
                end
                BSS_ISSUE: begin
                    if(abort_pending) finish_operation(DBG_ST_ABORTED);
                    else if(dma_ready) state<=BSS_WAIT;
                end
                BSS_WAIT: begin
                    if(dma_response) begin
                        if(abort_pending) finish_operation(DBG_ST_ABORTED);
                        else if(dma_status!=DBG_ST_OK) begin operation_address<=dma_error_address; finish_operation(dma_status); end
                        else if(zero_remaining<={14'd0,dma_completed,2'd0}) finish_operation(DBG_ST_OK);
                        else begin
                            zero_address<=zero_address+{14'd0,dma_completed,2'd0};
                            zero_remaining<=zero_remaining-{14'd0,dma_completed,2'd0}; state<=BSS_START;
                        end
                    end
                end
                default: begin end
            endcase
        end
    end
endmodule
