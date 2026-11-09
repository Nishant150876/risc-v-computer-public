`timescale 1ns/1ps

// ram: $readmemh init, port A rising-edge reads, port B falling-edge byte
// writes and read-first reads, and the single-cycle edge schedule:
//   rising edge:  PC <= next PC, port A latches the instruction at next PC
//   first half:   the instruction produces a data address (here: the word IS
//                 the address, the worst case dependency)
//   falling edge: port B reads that address
//   before the next rising edge: the loaded data must be valid.
// It also proves a store at a falling edge is visible to the next fetch and
// to the next load, and that a rising-edge port B (pipeline mode) is a full
// cycle late, which is why the single-cycle CPU uses the falling edge.
module ram_tb;
    localparam int WORDS = 16384;

    logic        clk = 1'b0;
    logic        a_en, b_en;
    logic [3:0]  b_wstrb;
    logic [31:0] a_addr, b_addr, b_wdata;
    logic [31:0] a_rdata, b_rdata, p_a_rdata, p_b_rdata;
    logic [31:0] model [0:WORDS-1];
    int unsigned checks = 0;

    ram #(.WORDS(WORDS), .PORTB_NEGEDGE(1'b1), .INIT_FILE("tb/data/ram_tb.mem")) dut (
        .clk(clk), .a_en(a_en), .a_addr(a_addr), .a_rdata(a_rdata),
        .b_en(b_en), .b_wstrb(b_wstrb), .b_addr(b_addr), .b_wdata(b_wdata),
        .b_rdata(b_rdata)
    );
    // Same memory in pipeline mode, driven identically.
    ram #(.WORDS(WORDS), .PORTB_NEGEDGE(1'b0), .INIT_FILE("tb/data/ram_tb.mem")) piped (
        .clk(clk), .a_en(a_en), .a_addr(a_addr), .a_rdata(p_a_rdata),
        .b_en(b_en), .b_wstrb(b_wstrb), .b_addr(b_addr), .b_wdata(b_wdata),
        .b_rdata(p_b_rdata)
    );

    // 40 ns period = 25 MHz, the single-cycle target.
    always #20 clk <= ~clk;

    task automatic expect_eq(input string what, input logic [31:0] got, exp);
        assert (got === exp) else $fatal(1, "%s: expected %h, got %h", what, exp, got);
        checks++;
    endtask

    // Port B write, held from just after one rising edge to just after the
    // next, so the falling-edge RAM and the rising-edge RAM each write once.
    task automatic store(input logic [31:0] addr, data, input logic [3:0] strb);
        @(posedge clk); #1;
        b_en = 1; b_addr = addr; b_wdata = data; b_wstrb = strb;
        @(posedge clk); #1;
        b_en = 0; b_wstrb = 0;
        for (int lane = 0; lane < 4; lane++)
            if (strb[lane]) model[addr[15:2]][lane*8 +: 8] = data[lane*8 +: 8];
    endtask

    logic [31:0] pc, pc_next, held, p_held;

    initial begin
        a_en = 0; b_en = 0; b_wstrb = 0; a_addr = 0; b_addr = 0; b_wdata = 0;
        for (int i = 0; i < WORDS; i++) model[i] = 32'h0;

        // 1. $readmemh image, including an @address record at the top word.
        // Reads use port A; port A must not change before a rising edge.
        @(negedge clk); a_en = 1; a_addr = 32'h0;
        @(posedge clk); #1; expect_eq("init word 0", a_rdata, 32'hdead_beef);
        a_addr = 32'h4;
        #10; expect_eq("port A holds until the rising edge", a_rdata, 32'hdead_beef);
        @(posedge clk); #1; expect_eq("init word 1", a_rdata, 32'h0000_0013);
        a_addr = 32'h0000_fffc;
        @(posedge clk); #1; expect_eq("init top word", a_rdata, 32'h1234_5678);
        a_addr = 32'h0001_0000;  // index bits wrap: only [15:2] are decoded
        @(posedge clk); #1; expect_eq("address bits above 15 ignored", a_rdata, 32'hdead_beef);
        model[0] = 32'hdead_beef; model[1] = 32'h0000_0013; model[WORDS-1] = 32'h1234_5678;

        // 2. Byte enables: every strobe pattern on one word.
        store(32'h100, 0, 4'hf); // define the word before any partial write
        for (int strb = 0; strb < 16; strb++) begin
            store(32'h100, 32'h0101_0101 * (strb + 1), 4'(strb));
            @(posedge clk); #1; a_addr = 32'h100;
            @(posedge clk); #1; expect_eq($sformatf("strobe %b", 4'(strb)), a_rdata, model[64]);
            expect_eq($sformatf("rising-edge mode strobe %b", 4'(strb)), p_a_rdata, model[64]);
        end

        // Disabled ports hold their read outputs; a disabled B must not write,
        // even when every byte strobe is high. Exercise both clock modes.
        a_en = 0; a_addr = 32'h104;
        held = b_rdata; p_held = p_b_rdata;
        b_en = 0; b_addr = 32'h100; b_wdata = 32'hffff_ffff; b_wstrb = 4'hf;
        repeat (2) begin
            @(posedge clk); #1;
            expect_eq("disabled A holds", a_rdata, model[64]);
            expect_eq("disabled pipeline A holds", p_a_rdata, model[64]);
            @(negedge clk); #1;
            expect_eq("disabled B holds", b_rdata, held);
            expect_eq("disabled pipeline B holds", p_b_rdata, p_held);
        end
        b_wstrb = 0; a_en = 1; a_addr = 32'h100;
        @(posedge clk); #1;
        expect_eq("disabled B did not write", a_rdata, model[64]);
        expect_eq("disabled pipeline B did not write", p_a_rdata, model[64]);

        // 3. Port B is read-first and changes only at the falling edge.
        @(posedge clk); #1;
        held = b_rdata;
        b_en = 1; b_addr = 32'h100; b_wdata = 32'hcafe_f00d; b_wstrb = 4'b1111;
        #10; expect_eq("port B holds until the falling edge", b_rdata, held);
        @(negedge clk); #1;
        expect_eq("port B read-first returns the old word", b_rdata, model[64]);
        model[64] = 32'hcafe_f00d;
        b_wstrb = 0;
        @(negedge clk); #1; expect_eq("port B reads the new word", b_rdata, 32'hcafe_f00d);
        b_en = 0;

        // 4. The edge schedule. Build a program whose words are pointers into
        // a data table, and a data table whose words are known values.
        for (int i = 0; i < 64; i++) store(32'(i * 4), 32'h8000 + 32'(i * 8), 4'hf);
        for (int i = 0; i < 64; i++) store(32'h8000 + 32'(i * 8), 32'ha5a5_0000 + 32'(i), 4'hf);

        @(posedge clk); #1;
        pc = 0; pc_next = 0; a_addr = pc_next;
        @(posedge clk);  // port A now holds mem[0]
        for (int i = 0; i < 64; i++) begin
            #1;
            // First half of the cycle: the fetched word is valid immediately
            // after the rising edge, and becomes the dependent load address.
            expect_eq($sformatf("fetch %0d valid after rising edge", i), a_rdata, model[pc[15:2]]);
            expect_eq("port A is the same in both modes", p_a_rdata, a_rdata);
            // ...the previous pipeline-mode load arrived a full cycle late.
            if (i > 0) expect_eq($sformatf("pipeline-mode load %0d one cycle late", i - 1),
                                 p_b_rdata, 32'ha5a5_0000 + 32'(i - 1));
            b_en = 1; b_wstrb = 0; b_addr = a_rdata;
            pc_next = pc + 4;
            a_addr = pc_next;
            @(negedge clk); #1;
            // Second half: the load result is already valid.
            expect_eq($sformatf("dependent load %0d valid before next rising edge", i),
                      b_rdata, 32'ha5a5_0000 + 32'(i));
            // In pipeline mode the same load has not happened yet...
            assert (p_b_rdata !== b_rdata)
                else $fatal(1, "rising-edge port B unexpectedly returned data in the same cycle");
            checks++;
            @(posedge clk);
            pc = pc_next;
        end
        #1; b_en = 0;

        // 5. A store at a falling edge is seen by the very next fetch (port A,
        // next rising edge) and by a load in the next cycle (port B).
        @(posedge clk); #1;
        a_addr = 32'h200;            // fetch address for the next cycle
        b_en = 1; b_addr = 32'h200; b_wdata = 32'h0badc0de; b_wstrb = 4'hf;
        @(negedge clk); #1; b_wstrb = 0;
        @(posedge clk); #1;
        expect_eq("fetch after store sees new word", a_rdata, 32'h0badc0de);
        @(negedge clk); #1;
        expect_eq("load after store sees new word", b_rdata, 32'h0badc0de);
        b_en = 0;

        $display("PASS: ram init, byte enables, read-first, and single-cycle fetch/dependent-load/store edge schedule (%0d checks)", checks);
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "TIMEOUT: ram test");
    end
endmodule
