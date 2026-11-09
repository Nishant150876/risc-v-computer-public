`timescale 1ns/1ps

module regfile_tb;
    logic clk = 1'b0;
    logic we = 1'b0;
    logic [4:0] waddr = '0;
    logic [31:0] wdata = '0;
    logic [4:0] raddr1 = '0;
    logic [4:0] raddr2 = '0;
    logic [31:0] plain1, plain2, bypass1, bypass2;
    logic [31:0] model [0:31];
    logic        known [0:31];  // no reset: unwritten registers are undefined
    logic [31:0] rng = 32'h32f1_2026;
    int unsigned checks = 0;

    regfile #(.BYPASS(1'b0)) plain (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .raddr1(raddr1), .raddr2(raddr2), .rdata1(plain1), .rdata2(plain2)
    );
    regfile #(.BYPASS(1'b1)) forwarded (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .raddr1(raddr1), .raddr2(raddr2), .rdata1(bypass1), .rdata2(bypass2)
    );

    always #5 clk <= ~clk;

    function automatic logic [31:0] random_word();
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        return rng;
    endfunction

    task automatic check_reads(input string phase);
        logic [31:0] e1, e2, f1, f2;
        bit k1, k2, b1, b2;
        e1 = model[raddr1];
        e2 = model[raddr2];
        f1 = e1;
        f2 = e2;
        k1 = known[raddr1];
        k2 = known[raddr2];
        b1 = k1;
        b2 = k2;
        if (we && waddr != 0) begin
            if (raddr1 == waddr) begin f1 = wdata; b1 = 1'b1; end
            if (raddr2 == waddr) begin f2 = wdata; b2 = 1'b1; end
        end
        // An unwritten register may hold anything; only known values are compared.
        if (!k1) begin e1 = plain1; end
        if (!k2) begin e2 = plain2; end
        if (!b1) begin f1 = bypass1; end
        if (!b2) begin f2 = bypass2; end
        assert ({plain1, plain2, bypass1, bypass2} === {e1, e2, f1, f2})
            else $fatal(1, "%s: reads x%0d/x%0d expected %h/%h bypass %h/%h; got %h/%h bypass %h/%h",
                        phase, raddr1, raddr2, e1, e2, f1, f2,
                        plain1, plain2, bypass1, bypass2);
        checks++;
    endtask

    task automatic cycle(
        input logic write_enable,
        input logic [4:0] destination,
        input logic [31:0] data,
        input logic [4:0] source1, source2
    );
        @(negedge clk);
        we = write_enable;
        waddr = destination;
        wdata = data;
        raddr1 = source1;
        raddr2 = source2;
        #1;
        check_reads("before edge");
        @(posedge clk);
        #1;
        if (write_enable && destination != 0) begin
            model[destination] = data;
            known[destination] = 1'b1;
        end
        check_reads("after edge");
    endtask

    initial begin
        for (int unsigned index = 0; index < 32; index++) begin
            model[index] = '0;
            known[index] = index == 0;
        end
        // Before any write only x0 is defined, and the bypass path still works.
        cycle(1'b1, 5'd3, 32'hffff_ffff, 5'd3, 5'd0);
        cycle(1'b0, 5'd0, 32'd0, 5'd0, 5'd31);
        for (int unsigned index = 1; index < 32; index++) begin
            cycle(1'b1, 5'(index), 32'h1020_3000 + index,
                  5'(index), 5'(index - 1));
        end
        for (int unsigned first = 0; first < 32; first++) begin
            for (int unsigned second = 0; second < 32; second++) begin
                cycle(1'b0, 5'd7, 32'hbad0_bad0, 5'(first), 5'(second));
            end
        end
        cycle(1'b1, 5'd0, 32'hffff_ffff, 5'd0, 5'd0);
        cycle(1'b1, 5'd9, 32'habcd_0123, 5'd9, 5'd9);
        cycle(1'b0, 5'd9, 32'hffff_ffff, 5'd9, 5'd9);
        cycle(1'b1, 5'd9, 32'h5555_5555, 5'd9, 5'd9);
        cycle(1'b0, 5'd9, 32'd0, 5'd9, 5'd31);

        // Back-to-back writes to one register: each read sees the newest
        // committed value, and with BYPASS the value about to be written.
        cycle(1'b1, 5'd12, 32'h1111_1111, 5'd12, 5'd12);
        cycle(1'b1, 5'd12, 32'h2222_2222, 5'd12, 5'd0);
        cycle(1'b1, 5'd12, 32'h3333_3333, 5'd0, 5'd12);
        cycle(1'b0, 5'd12, 32'h4444_4444, 5'd12, 5'd12);
        // Alternating writes to two registers while reading both.
        cycle(1'b1, 5'd30, 32'haaaa_aaaa, 5'd30, 5'd31);
        cycle(1'b1, 5'd31, 32'h5555_5555, 5'd30, 5'd31);
        cycle(1'b1, 5'd30, 32'h0f0f_0f0f, 5'd31, 5'd30);
        cycle(1'b0, 5'd31, 32'hdead_beef, 5'd30, 5'd31);

        for (int unsigned trial = 0; trial < 2000; trial++) begin
            logic [15:0] controls;
            logic [31:0] data;
            logic [4:0] destination, source1, source2;
            controls = 16'(random_word());
            data = random_word();
            destination = (trial % 17 == 0) ? 5'd0 : controls[4:0];
            source1 = (trial % 3 == 0) ? destination : controls[9:5];
            source2 = (trial % 4 == 0) ? destination : controls[14:10];
            cycle(controls[15], destination, data, source1, source2);
        end

        $display("PASS: regfile both BYPASS modes, all read pairs, x0, no-reset contract and random cycles (%0d checks; seed 32f12026)", checks);
        $finish;
    end

    initial begin
        #100_000;
        $fatal(1, "TIMEOUT: register-file test");
    end
endmodule
