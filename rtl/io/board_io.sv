`timescale 1ns/1ps

// Board registers: +0 LED write, +4 hex display write, +8 switch read,
// +12 button read. Byte strobes affect only the implemented low 16 bits.
// Buttons: bit 0 centre, 1 up, 2 left, 3 right, 4 down. Pins are active low
// for the common-anode display; digit 0 is the rightmost digit.
module board_io #(
    parameter int CLK_HZ = 25000000,
    parameter int SCAN_HZ = 4000,
    parameter int DEBOUNCE_CYCLES = 250000
) (
    input logic clk,
    input logic rst,
    input logic en,
    input logic [1:0] reg_sel,
    input logic [3:0] wstrb,
    input logic [31:0] wdata,
    output logic [31:0] rdata,
    input logic [15:0] switches,
    input logic [4:0] buttons,
    output logic [4:0] buttons_clean,
    output logic [15:0] led,
    output logic [15:0] display_value,
    output logic [6:0] seg,
    output logic [3:0] an,
    output logic dp
);
    localparam int DIGIT_CYCLES = CLK_HZ / SCAN_HZ;
    localparam int CW = (DIGIT_CYCLES > 1) ? $clog2(DIGIT_CYCLES) : 1;
    (* ASYNC_REG = "TRUE" *) logic [15:0] sw_meta, sw_sync;
    logic [CW-1:0] scan_count;
    logic [1:0] digit;
    logic [3:0] nibble;

    initial begin
        if (SCAN_HZ < 1 || DIGIT_CYCLES < 1) $fatal(1, "invalid display scan frequency");
    end

    debounce #(.WIDTH(5), .STABLE_CYCLES(DEBOUNCE_CYCLES)) u_buttons (
        .clk(clk), .rst(rst), .async_in(buttons), .clean(buttons_clean)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            sw_meta <= '0;
            sw_sync <= '0;
            scan_count <= '0;
            digit <= '0;
        end else begin
            sw_meta <= switches;
            sw_sync <= sw_meta;
            if (scan_count == CW'(DIGIT_CYCLES - 1)) begin
                scan_count <= '0;
                digit <= digit + 1'b1;
            end else scan_count <= scan_count + 1'b1;
        end
    end

    // Peripheral side effects use the same edge as CPU data RAM.
    always_ff @(negedge clk) begin
        if (rst) begin
            led <= '0;
            display_value <= '0;
        end else if (en) begin
            for (int lane = 0; lane < 2; lane++) begin
                if (wstrb[lane]) begin
                    if (reg_sel == 0) led[lane*8 +: 8] <= wdata[lane*8 +: 8];
                    if (reg_sel == 1) display_value[lane*8 +: 8] <= wdata[lane*8 +: 8];
                end
            end
        end
    end

    always_comb begin
        rdata = '0;
        case (reg_sel)
            2'd2: rdata = {16'b0, sw_sync};
            2'd3: rdata = {27'b0, buttons_clean};
            default: rdata = '0; // LED/display registers are write-only
        endcase
        nibble = display_value[4*int'(digit) +: 4];
        case (nibble)
            4'h0: seg = 7'b1000000;
            4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100;
            4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001;
            4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010;
            4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000;
            4'h9: seg = 7'b0010000;
            4'ha: seg = 7'b0001000;
            4'hb: seg = 7'b0000011;
            4'hc: seg = 7'b1000110;
            4'hd: seg = 7'b0100001;
            4'he: seg = 7'b0000110;
            4'hf: seg = 7'b0001110;
            default: seg = 7'b1111111;
        endcase
        an = ~(4'b0001 << digit);
        dp = 1'b1;
    end

    logic unused_upper;
    assign unused_upper = ^{wstrb[3:2], wdata[31:16]};
endmodule
