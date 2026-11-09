`timescale 1ns/1ps
module clock_gen_62mhz_tb;
    clock_gen_fast_tb #(.CPU_HZ(62500000)) test_fractional_clock ();
endmodule
