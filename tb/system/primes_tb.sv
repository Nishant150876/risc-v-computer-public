`timescale 1ns/1ps
// The complete real UART stream, not a synthesized/software-only checksum.
module primes_tb #(
    parameter bit PIPELINE = 0,
    parameter int CPU_HZ = 25000000
);
    localparam int BIT_CYCLES = (CPU_HZ+57600)/115200;
    localparam time BIT_TIME = 64'(BIT_CYCLES)*(1000000000/64'(CPU_HZ));
    logic clk = 0, btnC = 0, btnU = 0, btnL = 0, btnR = 0, btnD = 0, RsRx = 1;
    logic [15:0] sw = 0, led;
    logic RsTx, dp, Hsync, Vsync;
    logic [6:0] seg;
    logic [3:0] an, vgaRed, vgaGreen, vgaBlue;
    logic unused_board_pins;
    assign unused_board_pins = ^{dp,seg,an,vgaRed,vgaGreen,vgaBlue,Hsync,Vsync};
    string program_file, capture_path, measurements = "";
    int capture_file = 0;
    byte unsigned expected[$];
    int cursor = 0;
    int unsigned measured_cycles, measured_instret, cpi_whole, cpi_fraction;
    longint unsigned milli;
    bit line_complete = 0;
    basys3_soc #(.PIPELINE(PIPELINE),.CPU_HZ(CPU_HZ),.DEBOUNCE_CYCLES(3)) dut (.*);
    always #5 clk <= ~clk;
    initial forever begin
        logic [7:0] character;
        @(negedge RsTx); #(BIT_TIME/2);
        assert (!RsTx) else $fatal(1,"prime UART false start");
        for (int bit_index = 0; bit_index < 8; ++bit_index) begin #(BIT_TIME); character[bit_index] = RsTx; end
        #(BIT_TIME); assert (RsTx) else $fatal(1,"prime UART bad stop");
        if (capture_file != 0) $fwrite(capture_file,"%c",character);
        if (cursor < expected.size()) begin
            assert (character == expected[cursor]) else $fatal(1,"prime UART byte %0d got %h expected %h",cursor,character,expected[cursor]);
        end else begin
            assert (!line_complete) else $fatal(1,"extra prime output");
            measurements = {measurements,string'(character)};
            if (character == 10) line_complete = 1;
            assert (measurements.len() <= 100) else $fatal(1,"unbounded performance line");
        end
        cursor++;
    end
    initial begin
        int fixture, ch;
        fixture = $fopen("sw/programs/primes/uart.expect","r");
        assert (fixture != 0) else $fatal(1,"missing prime fixture");
        ch = $fgetc(fixture);
        while (ch != -1) begin
            if (ch == 10) expected.push_back(13);
            expected.push_back(8'(ch));
            ch = $fgetc(fixture);
        end
        $fclose(fixture);
        assert (expected.size() > 6000 && expected.size() < 16000) else $fatal(1,"prime fixture bounds");
        if (!$value$plusargs("program=%s",program_file)) $fatal(1,"primes_tb requires +program");
        for (int i = 0; i < 16384; ++i) dut.u_soc.u_ram.mem[i] = 32'ha5a5a5a5;
        $readmemh(program_file,dut.u_soc.u_ram.mem);
        if ($value$plusargs("capture=%s",capture_path)) begin
            capture_file = $fopen(capture_path,"wb");
            assert (capture_file != 0) else $fatal(1,"cannot create prime capture");
        end
        wait (line_complete && dut.halted);
        assert (dut.stop_cause == rv32i_pkg::STOP_EBREAK && led == 16'h7001 && dut.display_value == 16'h1229)
            else $fatal(1,"prime stop/signatures");
        assert ($sscanf(measurements,"cycles %d instret %d CPI %d.%d",measured_cycles,measured_instret,cpi_whole,cpi_fraction) == 4)
            else $fatal(1,"prime measurement format: %s",measurements);
        assert (measured_instret > 10000 && measured_cycles >= measured_instret && measured_cycles < CPU_HZ/2 && cpi_fraction < 1000)
            else $fatal(1,"prime measurement bounds: %s",measurements);
        milli = (64'(measured_cycles)*1000+64'(measured_instret)/2)/64'(measured_instret);
        assert (64'(cpi_whole)*1000+64'(cpi_fraction) == milli) else $fatal(1,"prime CPI arithmetic");
        // %d accepts "1.5" as well as "1.005"; require the exact zero-padded line.
        assert (measurements == $sformatf("cycles %0d instret %0d CPI %0d.%03d\r\n",
                measured_cycles,measured_instret,cpi_whole,cpi_fraction))
            else $fatal(1,"prime measurement line is not canonical: %s",measurements);
        if (capture_file != 0) $fclose(capture_file);
        $display("PASS: primes PIPELINE=%0d CPU_HZ=%0d exact 1229 primes, %0d UART bytes; sieve cycles=%0d instret=%0d CPI=%0d.%03d",PIPELINE,CPU_HZ,cursor,measured_cycles,measured_instret,cpi_whole,cpi_fraction);
        $finish;
    end
    initial begin #1500000000; $fatal(1,"TIMEOUT: prime board program"); end
endmodule
