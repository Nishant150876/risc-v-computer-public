`timescale 1ns/1ps
module snake_pipe_tb;
    snake_tb #(.PIPELINE(1),.CPU_HZ(62500000)) pipeline_board ();
endmodule
