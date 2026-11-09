`timescale 1ns/1ps
module uart_rx_tb;
    localparam int CPB = 217;
    localparam time BIT_TIME = CPB * 40;
    logic clk = 0, rst = 1, start = 0, tx, busy, rx, valid, framing_error;
    logic loopback = 1, manual_rx = 1;
    logic [7:0] tx_data = 0, data;
    logic [7:0] seen [2048];
    int rates [4] = '{980, 1020, 955, 1045};
    int received = 0, errors = 0;
    uart_tx #(.CLKS_PER_BIT(CPB)) transmitter (.clk(clk), .rst(rst), .start(start), .data(tx_data), .tx(tx), .busy(busy));
    assign rx = loopback ? tx : manual_rx;
    uart_rx #(.CLKS_PER_BIT(CPB)) dut (.clk(clk), .rst(rst), .rx(rx), .data(data), .valid(valid), .framing_error(framing_error));
    always #20 clk <= ~clk;
    initial forever begin
        @(posedge clk);
        #1;
        if (valid) begin seen[received] = data; received++; end
        if (framing_error) errors++;
    end
    task automatic frame(input logic [7:0] value, input time period, input bit good_stop = 1);
        #13; manual_rx = 0; #(period);
        for (int b = 0; b < 8; b++) begin manual_rx = value[b]; #(period); end
        manual_rx = good_stop; #(period);
    endtask
    initial begin
        repeat (3) @(negedge clk); rst = 0;
        for (int n = 0; n < 256; n++) begin
            @(negedge clk); start = 1; tx_data = 8'(n);
            @(negedge clk); start = 0;
            wait (!busy); repeat (4) @(negedge clk);
            assert (received == n + 1 && seen[n] == 8'(n) && errors == 0)
                else $fatal(1, "RX loopback byte %0d count %0d", n, received);
        end
        loopback = 0;
        // Sender rates in parts per thousand of 115200 baud. +/-2% is the
        // requirement; +/-4.5% still lands every sample inside its bit only
        // if the receiver samples near mid-bit (a quarter- or three-quarter-
        // bit sample point fails here), so this checks the sampling point.
        foreach (rates[r]) begin
            for (int n = 0; n < 256; n++) begin
                int before_count = received;
                frame(8'(n), BIT_TIME * 1000 / time'(rates[r]));
                repeat (5) @(negedge clk);
                assert (received == before_count + 1 && seen[before_count] == 8'(n) && errors == 0)
                    else $fatal(1, "RX at %0d/1000 of nominal baud, byte %0d", rates[r], n);
            end
        end
        // A short false start is rejected; a bad stop/break emits one error,
        // no byte, and recovers only once the line returns high.
        manual_rx = 0; #(BIT_TIME / 4); manual_rx = 1; #(BIT_TIME * 12);
        assert (received == 1280 && errors == 0) else $fatal(1, "false start accepted");
        frame(8'h55, BIT_TIME, 0);
        #(BIT_TIME * 20);
        assert (received == 1280 && errors == 1) else $fatal(1, "bad stop/break handling");
        manual_rx = 1; #(BIT_TIME * 2);
        frame(8'ha6, BIT_TIME); repeat (5) @(negedge clk);
        assert (received == 1281 && seen[1280] == 8'ha6) else $fatal(1, "RX break recovery");
        manual_rx = 0; #(BIT_TIME * 3); rst = 1;
        repeat (3) @(negedge clk); manual_rx = 1; rst = 0;
        #(BIT_TIME * 12);
        assert (received == 1281 && errors == 1) else $fatal(1, "RX reset leaked partial frame");
        frame(8'h3c, BIT_TIME); repeat (5) @(negedge clk);
        assert (received == 1282 && seen[1281] == 8'h3c) else $fatal(1, "RX reset recovery");
        $display("PASS: UART RX 256-byte TX loopback, all bytes at +/-2%% and +/-4.5%% baud (mid-bit sampling), false starts, bad stop, break and reset (%0d bytes)", received);
        $finish;
    end
    initial begin #200000000; $fatal(1, "TIMEOUT: UART RX"); end
endmodule
