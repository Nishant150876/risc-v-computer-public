`timescale 1ns/1ps
module uart_tb;
    localparam time BIT_TIME = 217 * 40;
    logic clk = 0, rst = 1, en = 0, re = 0, rx = 1, tx;
    logic [1:0] reg_sel = 0;
    logic [3:0] wstrb = 0;
    logic [31:0] wdata = 0, rdata, result;
    logic [7:0] sent [8];
    int transmitted = 0, checks = 0, overflow_rounds = 0, bad_rounds = 0;
    int unsigned rng = 32'hda7a2026; // fixed xorshift32 seed: reproducible traffic
    function automatic int unsigned next_random();
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
        return rng;
    endfunction
    uart dut (.*);
    always #20 clk <= ~clk;
    initial forever begin
        logic [7:0] value;
        @(negedge tx); #(BIT_TIME / 2);
        assert (!tx) else $fatal(1, "UART TX start");
        for (int b = 0; b < 8; b++) begin #(BIT_TIME); value[b] = tx; end
        #(BIT_TIME);
        assert (tx) else $fatal(1, "UART TX stop");
        sent[transmitted] = value; transmitted++;
    end
    task automatic access(input logic [1:0] regnum, input bit rd,
                          input logic [3:0] mask, input logic [31:0] value);
        @(posedge clk); #1; en = 1; re = rd; reg_sel = regnum; wstrb = mask; wdata = value;
        @(negedge clk); #1; result = rdata;
        @(posedge clk); #1; en = 0; re = 0; wstrb = 0;
        checks++;
    endtask
    task automatic receive_byte(input logic [7:0] value, input bit good_stop = 1);
        #13; rx = 0; #(BIT_TIME);
        for (int b = 0; b < 8; b++) begin rx = value[b]; #(BIT_TIME); end
        rx = good_stop; #(BIT_TIME);
        repeat (4) @(negedge clk);
    endtask
    initial begin
        repeat (3) @(negedge clk); rst = 0;
        access(1, 1, 0, 0);
        assert (result == 0 && tx) else $fatal(1, "UART initial status");
        access(0, 0, 2, 32'hff00); // lane 1 cannot send
        access(0, 0, 1, 32'hab);
        access(1, 1, 0, 0);
        assert (result == 1) else $fatal(1, "UART TX busy status");
        access(0, 0, 15, 32'hcd); // busy, ignored
        wait (!dut.tx_busy);
        assert (transmitted == 1 && sent[0] == 8'hab) else $fatal(1, "TX writes/lane/busy contract");
        access(0, 1, 0, 0);
        assert (result == 0) else $fatal(1, "TX register is write-only");
        access(2, 1, 0, 0);
        assert (result == 0) else $fatal(1, "empty FIFO read");
        for (int n = 0; n < 18; n++) receive_byte(8'(n));
        access(1, 1, 0, 0);
        assert (result == 6 && dut.count == 16) else $fatal(1, "FIFO full/overrun status");
        access(1, 0, 15, 0); access(2, 0, 15, 0);
        assert (dut.count == 16 && dut.overrun) else $fatal(1, "read-only register write changed FIFO/errors");
        for (int n = 0; n < 16; n++) begin
            access(2, 1, 0, 0);
            assert (result == 32'(n)) else $fatal(1, "FIFO order/drop-newest byte %0d got %h", n, result);
            assert (!dut.overrun) else $fatal(1, "RX read did not clear overrun");
        end
        access(1, 1, 0, 0);
        assert (result == 0) else $fatal(1, "FIFO did not drain");
        // Pointer wrap and a full FIFO's simultaneous pop/push.
        for (int n = 0; n < 16; n++) receive_byte(8'(n + 32));
        fork
            receive_byte(8'haa);
            begin
                wait (dut.rx_valid); #1;
                en = 1; re = 1; reg_sel = 2;
                @(negedge clk); #1; result = rdata;
                @(posedge clk); #1; en = 0; re = 0;
                assert (result == 32 && dut.count == 16 && !dut.overrun)
                    else $fatal(1, "full FIFO simultaneous pop/push");
            end
        join
        for (int n = 33; n < 48; n++) begin
            access(2, 1, 0, 0);
            assert (result == 32'(n)) else $fatal(1, "FIFO wrapped order");
        end
        access(2, 1, 0, 0);
        assert (result == 32'haa) else $fatal(1, "simultaneous arrival was lost");
        receive_byte(8'h55, 0); rx = 1; #(BIT_TIME * 2);
        access(1, 1, 0, 0);
        assert (result == 8) else $fatal(1, "bad frame was not reported/discarded");
        access(2, 1, 0, 0); access(1, 1, 0, 0);
        assert (result == 0) else $fatal(1, "RX read did not clear framing error");
        // A newly detected framing error must win a simultaneous RX-read clear.
        fork
            receive_byte(8'h55, 0);
            begin
                wait (dut.rx_frame_error); #1; en = 1; re = 1; reg_sel = 2;
                @(negedge clk);
                @(posedge clk); #1; en = 0; re = 0;
                assert (dut.frame_error) else $fatal(1, "new framing error lost to simultaneous clear");
            end
        join
        rx = 1; #(BIT_TIME * 2);
        access(1, 1, 0, 0);
        assert (result == 8) else $fatal(1, "new framing error not sticky");
        access(2, 1, 0, 0); access(1, 1, 0, 0);
        assert (result == 0) else $fatal(1, "second framing-error clear");
        // Seeded random traffic, checked against the bytes actually driven.
        // A polling reader that keeps up must see every byte, in order, with
        // no error flags, while arrivals and reads overlap at random offsets.
        begin
            logic [7:0] stream [64];
            int got = 0;
            for (int n = 0; n < 64; n++) stream[n] = 8'(next_random());
            fork
                for (int n = 0; n < 64; n++) begin
                    int unsigned gap_ns;
                    receive_byte(stream[n]);
                    gap_ns = next_random() % 17360; // up to two bit times
                    #(gap_ns);
                end
                while (got < 64) begin
                    access(1, 1, 0, 0);
                    assert (result[3:2] == 0) else $fatal(1, "random traffic raised error flags %b before byte %0d", result[3:2], got);
                    if (result[1]) begin
                        access(2, 1, 0, 0);
                        assert (result == 32'(stream[got]))
                            else $fatal(1, "random traffic byte %0d expected %h got %h", got, stream[got], result);
                        got++;
                    end
                    repeat (next_random() % 300) @(posedge clk);
                end
            join
        end
        // Random bursts of 0-40 frames (about 1 in 8 with a bad stop) while
        // nobody reads. Expected: the first 16 good bytes in order, overrun
        // only beyond 16, framing only after a bad frame; an empty read then
        // returns zero and clears both flags.
        for (int round = 0; round < 12; round++) begin
            logic [7:0] good [$];
            int burst;
            bit any_bad;
            burst = int'(next_random() % 41);
            any_bad = 0;
            good.delete();
            for (int n = 0; n < burst; n++) begin
                logic [7:0] value;
                bit bad;
                value = 8'(next_random());
                bad = (next_random() % 8) == 0;
                receive_byte(value, !bad);
                if (bad) begin rx = 1; #(BIT_TIME); any_bad = 1; end
                else good.push_back(value);
            end
            if (good.size() > 16) overflow_rounds++;
            if (any_bad) bad_rounds++;
            access(1, 1, 0, 0);
            assert (result == {28'b0, any_bad, good.size() > 16, good.size() != 0, 1'b0})
                else $fatal(1, "burst %0d (%0d good, bad=%0b) status %h", round, good.size(), any_bad, result);
            for (int n = 0; n < (good.size() < 16 ? good.size() : 16); n++) begin
                access(2, 1, 0, 0);
                assert (result == 32'(good[n]))
                    else $fatal(1, "burst %0d byte %0d expected %h got %h", round, n, good[n], result);
            end
            access(2, 1, 0, 0);
            assert (result == 0) else $fatal(1, "burst %0d: empty RX read returned %h", round, result);
            access(1, 1, 0, 0);
            assert (result == 0) else $fatal(1, "burst %0d did not drain and clear flags: status %h", round, result);
        end
        // The seed must actually exercise both overflow and framing bursts.
        assert (overflow_rounds > 0 && bad_rounds > 0)
            else $fatal(1, "random bursts lacked coverage: %0d overflow, %0d bad-frame rounds", overflow_rounds, bad_rounds);
        receive_byte(8'h78);
        @(negedge clk); rst = 1;
        repeat (3) @(negedge clk); rst = 0;
        access(1, 1, 0, 0);
        assert (result == 0 && tx && dut.count == 0) else $fatal(1, "UART system reset");
        $display("PASS: UART registers, lanes, busy rejection, 16-byte FIFO, overrun/drop-newest, wrap, simultaneous full pop/push, framing, seeded random traffic/bursts and reset (%0d MMIO checks; seed da7a2026)", checks);
        $finish;
    end
    initial begin #100000000; $fatal(1, "TIMEOUT: UART registers"); end
endmodule
