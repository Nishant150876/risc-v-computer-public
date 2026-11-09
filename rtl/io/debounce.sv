`timescale 1ns/1ps

// Synchronize each input, then accept a new level only after STABLE_CYCLES
// consecutive samples. Counters are independent; buttons need not move together.
module debounce #(
    parameter int WIDTH = 5,
    parameter int STABLE_CYCLES = 250000
) (
    input logic clk,
    input logic rst,
    input logic [WIDTH-1:0] async_in,
    output logic [WIDTH-1:0] clean
);
    localparam int CW = (STABLE_CYCLES > 1) ? $clog2(STABLE_CYCLES) : 1;
    (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] sync_meta, sync_data;
    logic [CW-1:0] count [WIDTH];

    initial begin
        if (STABLE_CYCLES < 1) $fatal(1, "STABLE_CYCLES must be positive");
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sync_meta <= '0;
            sync_data <= '0;
            clean <= '0;
            for (int i = 0; i < WIDTH; i++) count[i] <= '0;
        end else begin
            sync_meta <= async_in;
            sync_data <= sync_meta;
            for (int i = 0; i < WIDTH; i++) begin
                if (sync_data[i] == clean[i]) count[i] <= '0;
                else if (count[i] == CW'(STABLE_CYCLES - 1)) begin
                    clean[i] <= sync_data[i];
                    count[i] <= '0;
                end else count[i] <= count[i] + 1'b1;
            end
        end
    end
endmodule
