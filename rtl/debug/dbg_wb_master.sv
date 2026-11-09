`timescale 1ns/1ps
// Debug-only Wishbone B4 Classic. Native CPU memory interfaces do not use it.
// Byte addresses enter here; adr is an aligned word address on Wishbone.
module dbg_wb_master #(
    parameter int WATCHDOG_CYCLES=1024
) (
    input logic clk,rst,
    input logic request_valid,
    output logic request_ready,
    input logic request_write,
    input logic [31:0] request_address,request_data,
    input logic [3:0] request_select,
    output logic response_valid,
    input logic response_ready,
    output logic [31:0] response_data,
    output logic response_error,response_timeout,outcome_unknown,
    output logic wb_cyc,wb_stb,wb_we,
    output logic [29:0] wb_adr,
    output logic [31:0] wb_dat_w,
    output logic [3:0] wb_sel,
    input logic wb_ack,wb_err,
    input logic [31:0] wb_dat_r
);
    localparam int CW=(WATCHDOG_CYCLES<2) ? 1 : $clog2(WATCHDOG_CYCLES);
    typedef enum logic [1:0] {IDLE,BUS,REPLY} state_t;
    state_t state;
    logic [CW-1:0] remaining;
    initial if(WATCHDOG_CYCLES<1) $fatal(1,"Wishbone watchdog must be positive");
    assign request_ready=state==IDLE;
    assign response_valid=state==REPLY;
    assign wb_cyc=state==BUS;
    assign wb_stb=wb_cyc;
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE; remaining<=0; wb_we<=0; wb_adr<=0; wb_dat_w<=0; wb_sel<=0;
            response_data<=0; response_error<=0; response_timeout<=0; outcome_unknown<=0;
        end else case(state)
            IDLE: if(request_valid) begin
                wb_we<=request_write; wb_adr<=request_address[31:2];
                wb_dat_w<=request_data; wb_sel<=request_select;
                response_error<=0; response_timeout<=0; outcome_unknown<=0; response_data<=0;
                remaining<=CW'(WATCHDOG_CYCLES-1);
                if(request_address[1:0]!=0 || request_select==0) begin
                    response_error<=1; state<=REPLY;
                end else state<=BUS;
            end
            BUS: begin
                if(wb_err || wb_ack) begin
                    response_data<=wb_dat_r; response_error<=wb_err;
                    outcome_unknown<=wb_err && wb_we; state<=REPLY;
                end else if(remaining==0) begin
                    response_error<=1; response_timeout<=1; outcome_unknown<=wb_we; state<=REPLY;
                end else remaining<=remaining-1'b1;
            end
            REPLY: if(response_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
