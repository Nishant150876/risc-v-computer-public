`timescale 1ns/1ps

// 64 KB unified code/data RAM: 16K x 32-bit words, two ports, block RAM.
//   Port A: read-only instruction port, synchronous read on the rising edge.
//   Port B: data port with byte-write enables, read-first.
//           PORTB_NEGEDGE = 1 (single-cycle CPU): reads and writes on the
//           falling edge, so a load issued in the first half of a cycle
//           returns data before the next rising edge.
//           PORTB_NEGEDGE = 0 (pipeline): rising edge, like port A.
// Addresses are byte addresses; bits [1:0] are ignored and bits above
// [15:2] are not decoded here (the CPU side or bus selects the RAM).
module ram #(
    parameter int    WORDS         = 16384,
    parameter bit    PORTB_NEGEDGE = 1'b1,
    parameter string INIT_FILE     = ""
) (
    input  logic        clk,
    // Port A: instruction fetch
    input  logic        a_en,
    input  logic [31:0] a_addr,
    output logic [31:0] a_rdata,
    // Port B: loads and stores
    input  logic        b_en,
    input  logic [3:0]  b_wstrb,
    input  logic [31:0] b_addr,
    input  logic [31:0] b_wdata,
    output logic [31:0] b_rdata
);
    localparam int AW = $clog2(WORDS);

    logic [31:0] mem [0:WORDS-1];
    logic [AW-1:0] a_index, b_index;

    // Only the word-index bits are used; the rest belong to the address decoder.
    logic unused_addr;
    assign unused_addr = ^{a_addr[31:AW+2], a_addr[1:0], b_addr[31:AW+2], b_addr[1:0]};

    assign a_index = a_addr[AW+1:2];
    assign b_index = b_addr[AW+1:2];

    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always_ff @(posedge clk) begin
        if (a_en) a_rdata <= mem[a_index];
    end

    generate
        if (PORTB_NEGEDGE) begin : g_port_b_fall
            always_ff @(negedge clk) begin
                if (b_en) begin
                    b_rdata <= mem[b_index];
                    for (int lane = 0; lane < 4; lane++) begin
                        if (b_wstrb[lane]) mem[b_index][lane*8 +: 8] <= b_wdata[lane*8 +: 8];
                    end
                end
            end
        end else begin : g_port_b_rise
            always_ff @(posedge clk) begin
                if (b_en) begin
                    b_rdata <= mem[b_index];
                    for (int lane = 0; lane < 4; lane++) begin
                        if (b_wstrb[lane]) mem[b_index][lane*8 +: 8] <= b_wdata[lane*8 +: 8];
                    end
                end
            end
        end
    endgenerate
endmodule
