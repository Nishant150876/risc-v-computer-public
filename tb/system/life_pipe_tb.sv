`timescale 1ns/1ps
module life_pipe_tb;
    life_tb #(.PIPELINE(1),.CPU_HZ(62500000)) pipeline_board ();
endmodule
