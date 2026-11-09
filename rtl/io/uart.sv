`timescale 1ns/1ps

// CPU console UART, separate from the future framed debug endpoint.
// reg_sel: 0 TX, 1 STATUS, 2 RX. STATUS bits: busy, available, overrun,
// framing error. RX reads return the oldest byte (zero if empty), pop it,
// and clear both sticky errors; a simultaneous new error wins the clear.
// A TX write needs lane 0 and idle TX. Other writes have no effect.
// Native MMIO accepts at the falling edge, like RAM. Requests are staged
// to the following rising edge; all FIFO state has one rising-edge writer.
module uart #(
    parameter int CLK_HZ = 25000000,
    parameter int BAUD = 115200,
    parameter int FIFO_DEPTH = 16
) (
    input logic clk, rst,
    input logic en, re,
    input logic [1:0] reg_sel,
    input logic [3:0] wstrb,
    input logic [31:0] wdata,
    output logic [31:0] rdata,
    input logic rx,
    output logic tx
);
    localparam int CLKS_PER_BIT = (CLK_HZ + BAUD / 2) / BAUD;
    localparam int PW = $clog2(FIFO_DEPTH);
    logic tx_request, read_request, tx_busy;
    logic [7:0] tx_data, rx_data;
    logic rx_valid, rx_frame_error;
    logic [7:0] fifo [FIFO_DEPTH];
    logic [PW-1:0] read_ptr, write_ptr;
    logic [PW:0] count;
    logic overrun, frame_error, pop, push;
    initial if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0)
        $fatal(1, "UART FIFO depth must be a power of two >= 2");

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst(rst), .start(tx_request), .data(tx_data), .tx(tx), .busy(tx_busy)
    );
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst(rst), .rx(rx), .data(rx_data), .valid(rx_valid), .framing_error(rx_frame_error)
    );
    always_ff @(negedge clk) begin
        if (rst) begin
            tx_request <= 0;
            read_request <= 0;
            tx_data <= '0;
        end else begin
            tx_request <= en && reg_sel == 0 && wstrb[0] && !tx_busy;
            read_request <= en && re && reg_sel == 2;
            if (en && reg_sel == 0 && wstrb[0] && !tx_busy) tx_data <= wdata[7:0];
        end
    end
    assign pop = read_request && count != 0;
    assign push = rx_valid && (count < (PW+1)'(FIFO_DEPTH) || pop);
    always_ff @(posedge clk) begin
        if (rst) begin
            read_ptr <= '0;
            write_ptr <= '0;
            count <= '0;
            overrun <= 0;
            frame_error <= 0;
        end else begin
            if (read_request) begin
                overrun <= 0;
                frame_error <= 0;
            end
            if (rx_frame_error) frame_error <= 1;
            if (rx_valid && !push) overrun <= 1; // drop newest; retain unread FIFO bytes
            if (push) begin
                fifo[write_ptr] <= rx_data;
                write_ptr <= write_ptr + 1'b1;
            end
            if (pop) read_ptr <= read_ptr + 1'b1;
            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: ;
            endcase
        end
    end
    always_comb begin
        rdata = '0;
        case (reg_sel)
            2'd1: rdata = {28'b0, frame_error, overrun, count != 0, tx_busy};
            2'd2: if (count != 0) rdata = {24'b0, fifo[read_ptr]};
            default: ;
        endcase
    end
    logic unused_upper;
    assign unused_upper = ^{wstrb[3:1], wdata[31:8]};
endmodule
