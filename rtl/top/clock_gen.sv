`timescale 1ns/1ps

// Hardware: 100 MHz -> 1 GHz MMCM VCO -> CPU_HZ through a BUFG. CPU_HZ must
// divide the VCO by 2.0-128.0 in steps of 0.125 (25 MHz: 40.0, 50 MHz: 20.0).
// Pixel clock stays at 25 MHz. Simulation supports 25/50/62.5 MHz CPU settings.
// CPU reset never resets this clock manager, so stopped CPUs keep board I/O
// and future transport clocks alive. rst is for clock-manager reset only.
module clock_gen #(
    parameter int CPU_HZ = 25000000
) (
    input logic clk,
    input logic rst,
    output logic clk_cpu,
    output logic clk_pixel,
    output logic locked
);
`ifdef VERILATOR
    // Functional simulation model only. Vivado never synthesizes this divider.
    initial if (CPU_HZ != 25000000 && CPU_HZ != 50000000 && CPU_HZ != 62500000)
        $fatal(1, "simulation clock model supports 25/50/62.5 MHz CPU only");
    logic [1:0] sim_div = 0;
    logic [3:0] sim_lock_count = 0;
    logic sim_locked = 0;
    always_ff @(posedge clk) begin
        if (rst) begin
            sim_div <= '0;
            sim_lock_count <= '0;
            sim_locked <= 0;
        end else begin
            sim_div <= sim_div + 1'b1;
            if (!sim_locked) begin
                if (sim_lock_count == 7) sim_locked <= 1;
                else sim_lock_count <= sim_lock_count + 1'b1;
            end
        end
    end
    generate
        if (CPU_HZ == 62500000) begin : g_sim_fractional
            // A 16 ns period cannot be represented by an integer divider of
            // the 10 ns input. Timed model only; hardware uses the MMCM below.
            logic sim_cpu = 0;
            always #8 sim_cpu <= rst ? 1'b0 : ~sim_cpu;
            assign clk_cpu = sim_cpu;
        end else begin : g_sim_integer
            assign clk_cpu = CPU_HZ == 50000000 ? sim_div[0] : sim_div[1];
        end
    endgenerate
    assign clk_pixel = sim_div[1];
    assign locked = sim_locked;
`else
    localparam real DIVIDE = 1000.0e6 / CPU_HZ;
    initial begin
        if (DIVIDE < 2.0 || DIVIDE > 128.0 || DIVIDE * 8.0 != $rtoi(DIVIDE * 8.0))
            $error("CPU_HZ %0d is not an MMCM CLKOUT0 setting from a 1 GHz VCO", CPU_HZ);
    end
    wire feedback, feedback_buf, clock_raw, pixel_raw;
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"), .CLKIN1_PERIOD(10.0),
        .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(10.0),
        .CLKOUT0_DIVIDE_F(DIVIDE), .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE(0.0), .CLKOUT1_DIVIDE(40),
        .CLKOUT1_DUTY_CYCLE(0.5), .CLKOUT1_PHASE(0.0), .STARTUP_WAIT("FALSE")
    ) u_mmcm (
        .CLKIN1(clk), .CLKFBIN(feedback_buf), .CLKFBOUT(feedback),
        .CLKOUT0(clock_raw), .LOCKED(locked), .PWRDWN(1'b0), .RST(rst),
        .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(pixel_raw), .CLKOUT1B(),
        .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
    );
    BUFG u_feedback (.I(feedback), .O(feedback_buf));
    BUFG u_cpu_clock (.I(clock_raw), .O(clk_cpu));
    BUFG u_pixel_clock (.I(pixel_raw), .O(clk_pixel));
`endif
endmodule
