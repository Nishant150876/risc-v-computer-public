`timescale 1ns/1ps

// Phase 0 blink: proves the scripted Vivado flow end to end.
// The 16 LEDs show a binary count. With the default DIV_BITS = 24 and the
// 100 MHz board clock, the count advances about 6 times a second, so LED 0
// blinks at about 3 Hz and each higher LED at half the rate of the one below.
// The centre button (btnC) is reset; it is synchronized before use.
module basys3_top #(
    parameter int DIV_BITS = 24   // 2**DIV_BITS clocks per LED count step
) (
    input  logic        clk,      // 100 MHz oscillator, pin W5
    input  logic        btnC,     // centre push button, active high
    output logic [15:0] led
);
    // Two-flop synchronizer: the button is asynchronous to clk.
    logic [1:0] rst_sync = 2'b11;
    logic       rst;

    always_ff @(posedge clk) begin
        rst_sync <= {rst_sync[0], btnC};
    end
    assign rst = rst_sync[1];

    logic [DIV_BITS+15:0] count = '0;

    always_ff @(posedge clk) begin
        if (rst) begin
            count <= '0;
        end else begin
            count <= count + 1'b1;
        end
    end

    assign led = count[DIV_BITS+15:DIV_BITS];
endmodule
