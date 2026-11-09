`timescale 1ns/1ps
// Simulation-only FIFO bridge for the actual Python client. Not a CPU model.
// The host supplies bounded wire hex lines; replies are the DUT's actual bytes.
module dbg_host_server;
    import dbg_pkg::*;
    import rv32i_pkg::*;
    logic clk=0,rst=1,rx_valid=0,rx_ready,tx_valid,tx_ready=1,abort_frame=0;
    logic [7:0] rx_data=0,tx_data;
    logic [31:0] now_ms=0,rejected_frames;
    logic [14:0] divider=0;
    logic console_tx;
    logic [15:0] led,display_value;
    retire_t retire;
    integer requests,replies;
    string request_path,reply_path,line;
    logic reply_done=0;
    logic unused_outputs;
    assign unused_outputs=^{rejected_frames,retire,led,display_value,console_tx};
    dbg_system dut(.clk(clk),.rst(rst),.now_ms(now_ms),.rx_valid(rx_valid),.abort_frame(abort_frame),
        .rx_data(rx_data),.rx_ready(rx_ready),.tx_valid(tx_valid),.tx_data(tx_data),.tx_ready(tx_ready),
        .cpu_reset_req(1'b0),.console_rx(1'b1),.console_tx(console_tx),.switches(16'd0),.buttons(5'd0),
        .led(led),.display_value(display_value),.retire(retire),.rejected_frames(rejected_frames));
    always #20 clk<=~clk;
    always_ff @(posedge clk) begin
        if(rst) begin divider<=0; now_ms<=0; end
        else if(divider==24999) begin divider<=0; now_ms<=now_ms+1'b1; end
        else divider<=divider+1'b1;
    end
    initial forever begin
        @(posedge clk);
        if(tx_valid && tx_ready) begin
            $fwrite(replies,"%02x",tx_data);
            if(tx_data==0) begin $fwrite(replies,"\n"); $fflush(replies); reply_done=1; end
        end
    end
    function automatic logic [3:0] nibble(input byte value);
        if(value>="0" && value<="9") return 4'(value-"0");
        if(value>="a" && value<="f") return 4'(value-8'h61+8'd10);
        $fatal(1,"non-hex host wire line"); return 0;
    endfunction
    initial begin
        if(!$value$plusargs("requests=%s",request_path) || !$value$plusargs("replies=%s",reply_path))
            $fatal(1,"FIFO paths required");
        requests=$fopen(request_path,"r"); replies=$fopen(reply_path,"w");
        assert(requests!=0 && replies!=0) else $fatal(1,"cannot open host FIFOs");
        repeat(5) @(negedge clk); rst=0; repeat(8) @(negedge clk);
        forever begin
            int chars,bytes,waited;
            chars=$fgets(line,requests);
            if(chars==0 || line==".\n") begin $fclose(requests); $fclose(replies); $finish; end
            assert(chars>2 && chars<=DBG_MAX_WIRE*2+1 && line.getc(chars-1)==10 && chars%2==1)
                else $fatal(1,"unbounded/malformed host line");
            bytes=(chars-1)/2; reply_done=0;
            for(int i=0;i<bytes;i=i+1) begin
                @(negedge clk); wait(rx_ready);
                rx_data={nibble(line.getc(2*i)),nibble(line.getc(2*i+1))}; rx_valid=1;
                @(negedge clk); rx_valid=0;
            end
            waited=0;
            while(!reply_done) begin
                @(negedge clk); waited=waited+1;
                if(waited>100000) $fatal(1,"DUT did not terminate the packet request");
            end
            // Give asynchronous verify/BIST and a running CPU deterministic
            // simulation time between host requests. Wall time is not hardware time.
            repeat(10000) @(negedge clk);
        end
    end
endmodule
