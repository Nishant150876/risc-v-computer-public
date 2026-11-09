`timescale 1ns/1ps

// soc_tb with the pipelined CPU selected (PIPELINE = 1). Same checks and
// plusargs; scripts/run_tests.py compiles tb/soc_tb.sv with this wrapper.
module soc_pipe_tb;
    soc_tb #(.PIPELINE(1'b1)) u_tb ();
endmodule
