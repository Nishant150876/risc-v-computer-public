`timescale 1ns/1ps

// Load/store unit: lane steering between the CPU and a 32-bit, byte-enabled
// memory port. Purely combinational.
//
// Alignment contract: LH/LHU/SH need addr[0] = 0, LW/SW need addr[1:0] = 0.
// A misaligned access raises misaligned and is fully suppressed (no read
// enable, no byte enables); the CPU stops without retiring it.
module lsu (
    input  logic                  mem_read,
    input  logic                  mem_write,
    input  rv32i_pkg::mem_size_t  size,
    input  logic                  is_unsigned,
    input  logic [1:0]            addr_offset, // byte address bits [1:0]
    input  logic [31:0]           store_data,  // rs2
    input  logic [31:0]           mem_rdata,   // raw word at addr[31:2]
    output logic                  mem_re,
    output logic [3:0]            mem_wstrb,
    output logic [31:0]           mem_wdata,
    output logic [31:0]           load_data,   // extended, for rd
    output logic                  misaligned
);
    import rv32i_pkg::*;

    logic [1:0]  offset;
    logic [7:0]  byte_lane;
    logic [15:0] half_lane;
    logic [3:0]  strb;

    always_comb begin
        offset = addr_offset;

        case (size)
            MEM_BYTE: misaligned = 1'b0;
            MEM_HALF: misaligned = offset[0];
            MEM_WORD: misaligned = offset != 2'b00;
            default:  misaligned = 1'b1;
        endcase
        misaligned = misaligned && (mem_read || mem_write);

        // Store: replicate the data so every lane holds the right bytes, then
        // enable only the addressed lanes.
        case (size)
            MEM_BYTE: begin
                mem_wdata = {4{store_data[7:0]}};
                strb = 4'b0001 << offset;
            end
            MEM_HALF: begin
                mem_wdata = {2{store_data[15:0]}};
                strb = offset[1] ? 4'b1100 : 4'b0011;
            end
            default: begin
                mem_wdata = store_data;
                strb = 4'b1111;
            end
        endcase
        mem_wstrb = (mem_write && !misaligned) ? strb : 4'b0000;
        mem_re    = mem_read && !misaligned;

        // Load: select the lane, then sign- or zero-extend.
        case (offset)
            2'd0: byte_lane = mem_rdata[7:0];
            2'd1: byte_lane = mem_rdata[15:8];
            2'd2: byte_lane = mem_rdata[23:16];
            default: byte_lane = mem_rdata[31:24];
        endcase
        half_lane = offset[1] ? mem_rdata[31:16] : mem_rdata[15:0];
        case (size)
            MEM_BYTE: load_data = is_unsigned ? {24'd0, byte_lane}
                                              : {{24{byte_lane[7]}}, byte_lane};
            MEM_HALF: load_data = is_unsigned ? {16'd0, half_lane}
                                              : {{16{half_lane[15]}}, half_lane};
            default:  load_data = mem_rdata;
        endcase
    end
endmodule
