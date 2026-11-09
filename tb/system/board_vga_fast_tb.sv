`timescale 1ns/1ps
module board_vga_fast_tb;
    board_vga_tb #(.PIPELINE(1), .CPU_HZ(62500000)) pipeline_fast_board ();
endmodule
