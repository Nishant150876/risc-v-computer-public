`timescale 1ns/1ps

// 8N1 receiver. Synchronize the pin, validate the middle of the start bit,
// then sample data and stop at one-bit intervals. A bad stop is discarded.
// After a break, require a high level before searching for another start.
module uart_rx #(
    parameter int CLKS_PER_BIT = 217
) (
    input logic clk, rst,
    input logic rx,
    output logic [7:0] data,
    output logic valid, framing_error
);
    localparam int CW = $clog2(CLKS_PER_BIT);
    typedef enum logic [2:0] {IDLE, START, DATA, STOP, RECOVER} state_t;
    state_t state;
    (* ASYNC_REG = "TRUE" *) logic rx_meta, rx_sync;
    logic [CW-1:0] timer;
    logic [2:0] bit_index;
    logic [7:0] shift;
    initial if (CLKS_PER_BIT < 8) $fatal(1, "UART RX requires at least eight clocks per bit");

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_meta <= 1;
            rx_sync <= 1;
            state <= IDLE;
            timer <= '0;
            bit_index <= '0;
            shift <= '0;
            data <= '0;
            valid <= 0;
            framing_error <= 0;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
            valid <= 0;
            framing_error <= 0;
            case (state)
                IDLE: if (!rx_sync) begin
                    timer <= CW'(CLKS_PER_BIT / 2 - 1);
                    state <= START;
                end
                START: if (timer != 0) timer <= timer - 1'b1;
                else if (rx_sync) state <= IDLE;
                else begin
                    timer <= CW'(CLKS_PER_BIT - 1);
                    bit_index <= 0;
                    state <= DATA;
                end
                DATA: if (timer != 0) timer <= timer - 1'b1;
                else begin
                    shift[bit_index] <= rx_sync;
                    timer <= CW'(CLKS_PER_BIT - 1);
                    if (bit_index == 7) state <= STOP;
                    else bit_index <= bit_index + 1'b1;
                end
                STOP: if (timer != 0) timer <= timer - 1'b1;
                else if (rx_sync) begin
                    data <= shift;
                    valid <= 1;
                    state <= IDLE;
                end else begin
                    framing_error <= 1;
                    state <= RECOVER;
                end
                RECOVER: if (rx_sync) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
