`timescale 1ns/1ps
// The existing two RAM ports are lent, never replicated. Debug and BIST use
// one selected Classic master. This adapter works with either RAM B edge.
module dbg_ram_arbiter (
    input logic clk,rst,
    input logic cpu_safe,debug_claim,bist_claim,
    output logic debug_grant,bist_grant,cpu_owns,
    input logic cpu_a_en,
    input logic [31:0] cpu_a_addr,
    input logic cpu_b_en,
    input logic [31:0] cpu_b_addr,cpu_b_wdata,
    input logic [3:0] cpu_b_wstrb,
    output logic ram_a_en,ram_b_en,
    output logic [31:0] ram_a_addr,ram_b_addr,ram_b_wdata,
    output logic [3:0] ram_b_wstrb,
    input logic [31:0] ram_b_rdata,
    input logic wb_cyc,wb_stb,wb_we,
    input logic [29:0] wb_adr,
    input logic [31:0] wb_dat_w,
    input logic [3:0] wb_sel,
    input logic wb_bist,
    input logic fault_enable,
    input logic [31:0] fault_address,fault_mask,
    output logic fault_fired,
    output logic [31:0] fault_original,fault_observed,
    output logic wb_ack,wb_err,
    output logic [31:0] wb_dat_r
);
    typedef enum logic [2:0] {CPU,WAIT_DEBUG,WAIT_BIST,DEBUG,BIST,PRIME} owner_t;
    typedef enum logic [1:0] {WB_IDLE,WB_ISSUE,WB_WAIT,WB_REPLY} bus_t;
    owner_t owner;
    bus_t bus_state;
    logic quiet;
    logic [31:0] address,data;
    logic [3:0] selects;
    logic write_enable;
    logic bus_idle,allowed;
    logic fault_used;
    assign debug_grant=owner==DEBUG;
    assign bist_grant=owner==BIST;
    assign cpu_owns=owner==CPU || owner==WAIT_DEBUG || owner==WAIT_BIST;
    assign bus_idle=bus_state==WB_IDLE && !(wb_cyc && wb_stb);
    assign allowed=cpu_safe && ((debug_grant && !wb_bist)||(bist_grant && wb_bist));
    assign ram_a_addr=cpu_a_addr;
    always_comb begin
        ram_a_en=0; ram_b_en=0; ram_b_addr=0; ram_b_wdata=0; ram_b_wstrb=0;
        if(!rst) begin
            ram_a_en=cpu_a_en && owner!=DEBUG && owner!=BIST;
            if(owner==CPU || owner==WAIT_DEBUG || owner==WAIT_BIST) begin
                ram_b_en=cpu_b_en; ram_b_addr=cpu_b_addr;
                ram_b_wdata=cpu_b_wdata; ram_b_wstrb=cpu_b_wstrb;
            end else if(bus_state==WB_ISSUE && wb_cyc && wb_stb && allowed) begin
                ram_b_en=1; ram_b_addr=address; ram_b_wdata=data;
                ram_b_wstrb=write_enable ? selects : 4'd0;
            end
        end
    end
    always_ff @(posedge clk) begin
        if(rst) begin owner<=CPU; quiet<=0; end
        else case(owner)
            CPU: begin
                quiet<=0;
                if(debug_claim) owner<=WAIT_DEBUG;
                else if(bist_claim) owner<=WAIT_BIST;
            end
            WAIT_DEBUG,WAIT_BIST: begin
                if((owner==WAIT_DEBUG && !debug_claim)||(owner==WAIT_BIST && !bist_claim)) begin owner<=CPU; quiet<=0; end
                else if(cpu_safe && !cpu_b_en) begin
                    if(quiet) owner<=owner==WAIT_DEBUG ? DEBUG : BIST;
                    quiet<=1;
                end else quiet<=0;
            end
            DEBUG: if(!debug_claim && bus_idle) owner<=PRIME;
            BIST: if(!bist_claim && bus_idle) owner<=PRIME;
            PRIME: owner<=CPU; // one rising fetch edge before acknowledging return
            default: owner<=CPU;
        endcase
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            bus_state<=WB_IDLE; wb_ack<=0; wb_err<=0; wb_dat_r<=0;
            address<=0; data<=0; selects<=0; write_enable<=0;
            fault_used<=0; fault_fired<=0; fault_original<=0; fault_observed<=0;
        end else begin
            wb_ack<=0; wb_err<=0;
            fault_fired<=0;
            if(!fault_enable) fault_used<=0;
            case(bus_state)
                WB_IDLE: if(wb_cyc && wb_stb) begin
                    if(!allowed || wb_adr[29:14]!=0 || wb_sel==0) begin
                        wb_err<=1; bus_state<=WB_REPLY;
                    end else begin
                        address<={16'd0,wb_adr[13:0],2'd0}; data<=wb_dat_w;
                        selects<=wb_sel; write_enable<=wb_we; bus_state<=WB_ISSUE;
                    end
                end
                WB_ISSUE: if(!wb_cyc || !wb_stb) bus_state<=WB_IDLE;
                          else bus_state<=WB_WAIT;
                WB_WAIT: begin
                    if(wb_cyc && wb_stb) begin
                        wb_dat_r<=ram_b_rdata;
                        if(allowed && owner==BIST && !write_enable && fault_enable && !fault_used &&
                           address==fault_address && address>=32'hd000 && address<32'he000 && fault_mask!=0) begin
                            wb_dat_r<=ram_b_rdata^fault_mask; fault_used<=1; fault_fired<=1;
                            fault_original<=ram_b_rdata; fault_observed<=ram_b_rdata^fault_mask;
                        end
                        if(allowed) wb_ack<=1; else wb_err<=1;
                        bus_state<=WB_REPLY;
                    end else bus_state<=WB_IDLE;
                end
                WB_REPLY: if(!wb_cyc || !wb_stb) bus_state<=WB_IDLE;
                default: bus_state<=WB_IDLE;
            endcase
        end
    end
endmodule
