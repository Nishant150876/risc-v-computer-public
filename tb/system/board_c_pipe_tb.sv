`timescale 1ns/1ps

// board_c_tb with the pipelined CPU selected (PIPELINE = 1). Same checks and
// plusargs; scripts/run_tests.py compiles tb/board_c_tb.sv with this wrapper.
module board_c_pipe_tb;
    board_c_tb #(.PIPELINE(1'b1)) u_tb ();
endmodule
