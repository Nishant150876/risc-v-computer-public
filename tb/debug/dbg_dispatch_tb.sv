`timescale 1ns/1ps
module dbg_dispatch_tb;
    import dbg_pkg::*;
    logic clk=0,rst=1,request_valid=0,request_ready,response_valid,response_ready=1;
    logic [31:0] now_ms=0,rejected_requests;
    logic [63:0] active_session;
    logic [DBG_MAX_PAYLOAD*8-1:0] identity_payload,status_payload='0,result_payload;
    logic execute_valid,result_valid,result_ready;
    logic [15:0] result_status=DBG_ST_OK,result_length=4;
    dbg_frame_t request,response,execute_request,saved_reply,observed;
    int completions=0;
    logic unused_exec_fields;
    assign unused_exec_fields=^execute_request;
    assign identity_payload=dbg_identity(32'h12345678,25000000,DBG_CAP_BASE_STATUS,DBG_CPU_ABSENT);
    assign result_payload={{(DBG_MAX_PAYLOAD*8-32){1'b0}},32'(completions)};
    dbg_dispatch #(.EXTERNAL_COMMANDS(1)) dut (
        .clk(clk),.rst(rst),.now_ms(now_ms),.identity_payload(identity_payload),.status_payload(status_payload),
        .request_valid(request_valid),.request_ready(request_ready),.request(request),
        .response_valid(response_valid),.response_ready(response_ready),.response(response),
        .execute_valid(execute_valid),.execute_ready(1'b1),.execute_request(execute_request),
        .result_valid(result_valid),.result_ready(result_ready),.result_status(result_status),
        .result_length(result_length),.result_payload(result_payload),
        .rejected_requests(rejected_requests),.active_session(active_session));
    always #5 clk<=~clk;
    initial begin
        result_valid=0;
        forever begin
            wait(execute_valid);
            assert(execute_request.opcode==DBG_OP_MEM_WRITE) else $fatal(1,"wrong external request");
            @(negedge clk); completions=completions+1;
            repeat(5) @(negedge clk);
            assert(result_ready) else $fatal(1,"execution response was not accepted");
            result_valid=1;
            @(negedge clk); result_valid=0;
        end
    end
    task automatic command(input logic [15:0] opcode,input logic [31:0] id,input logic [63:0] session_id,
                           input logic [15:0] expect_status);
        @(negedge clk); wait(request_ready);
        request='0; request.version=DBG_PROTOCOL_VERSION; request.opcode=opcode;
        request.request_id=id; request.session_id=session_id; request_valid=1;
        @(negedge clk); request_valid=0;
        wait(response_valid); observed=response;
        assert(response.status==expect_status) else $fatal(1,"op%h id%0d status%h expected%h",opcode,id,response.status,expect_status);
        @(negedge clk);
    endtask
    initial begin
        request='0; repeat(3) @(negedge clk); rst=0;
        command(DBG_OP_HELLO,1,64'h1234,DBG_ST_OK);
        response_ready=0;
        command(DBG_OP_MEM_WRITE,2,64'h1234,DBG_ST_OK);
        saved_reply=observed;
        repeat(10) begin @(negedge clk); assert(response==saved_reply && response_valid) else $fatal(1,"held reply changed"); end
        response_ready=1; @(negedge clk);
        command(DBG_OP_MEM_WRITE,2,64'h1234,DBG_ST_OK);
        assert(observed==saved_reply && completions==1) else $fatal(1,"retry executed twice");
        command(DBG_OP_STATUS,2,64'h1234,DBG_ST_ID_CONFLICT);
        command(DBG_OP_PING,1,64'h1234,DBG_ST_STALE_REQUEST);
        command(DBG_OP_HELLO,1,64'h5678,DBG_ST_BUSY);
        now_ms=2001;
        command(DBG_OP_STATUS,3,64'h1234,DBG_ST_BAD_SESSION);
        command(DBG_OP_HELLO,1,64'h5678,DBG_ST_OK);
        assert(active_session==64'h5678 && rejected_requests==0) else $fatal(1,"session transfer");
        // Debug reset clears replay/session state independently of any CPU.
        @(negedge clk); rst=1; @(negedge clk); rst=0;
        assert(active_session==0) else $fatal(1,"session survived debug reset");
        $display("PASS: debug dispatcher exactly-once external execution, immutable held/replayed reply, ID conflict/stale, BUSY and lease/reset recovery");
        $finish;
    end
    initial begin #200000; $fatal(1,"TIMEOUT debug dispatcher"); end
endmodule
