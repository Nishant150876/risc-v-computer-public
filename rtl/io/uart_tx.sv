`timescale 1ns/1ps

// 8N1, LSB first. A start is accepted only while idle; data is latched.
// busy includes the entire stop bit. Every bit lasts CLKS_PER_BIT clocks.
module uart_tx #(
    parameter int CLKS_PER_BIT = 217
) (
    input logic clk, rst,
    input logic start,
    input logic [7:0] data,
    output logic tx, busy
);
    localparam int CW = $clog2(CLKS_PER_BIT);
    logic [CW-1:0] timer;
    logic [9:0] frame;
    logic [3:0] bit_index;
    initial if (CLKS_PER_BIT < 2) $fatal(1, "UART bit period must be at least two clocks");
    assign tx = busy ? frame[0] : 1'b1;

    always_ff @(posedge clk) begin
        if (rst) begin
            busy <= 0;
            timer <= '0;
            frame <= '1;
            bit_index <= '0;
        end else if (!busy) begin
            if (start) begin
                busy <= 1;
                frame <= {1'b1, data, 1'b0};
                timer <= CW'(CLKS_PER_BIT - 1);
                bit_index <= '0;
            end
        end else if (timer != 0) timer <= timer - 1'b1;
        else begin
            timer <= CW'(CLKS_PER_BIT - 1);
            frame <= {1'b1, frame[9:1]};
            if (bit_index == 9) busy <= 0;
            else bit_index <= bit_index + 1'b1;
        end
    end
endmodule
