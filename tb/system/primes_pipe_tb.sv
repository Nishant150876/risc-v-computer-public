`timescale 1ns/1ps
module primes_pipe_tb;
    primes_tb #(.PIPELINE(1),.CPU_HZ(62500000)) pipeline_board ();
endmodule
