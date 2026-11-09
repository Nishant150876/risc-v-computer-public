`timescale 1ns/1ps

// basys3_soc_tb with the pipelined CPU selected (PIPELINE = 1). Same checks and
// plusargs; scripts/run_tests.py compiles tb/basys3_soc_tb.sv with this wrapper.
module basys3_soc_pipe_tb;
    basys3_soc_tb #(.PIPELINE(1'b1)) u_tb ();
endmodule
