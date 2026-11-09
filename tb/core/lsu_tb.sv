`timescale 1ns/1ps

// lsu: every size, offset and signedness for loads; byte enables and lane
// data for stores; the alignment contract (misaligned accesses suppressed).
// The reference works byte by byte through a little-endian memory model.
module lsu_tb;
    import rv32i_pkg::*;

    logic        mem_read, mem_write, is_unsigned;
    mem_size_t   size;
    logic [1:0]  offset;
    logic [31:0] store_data, mem_rdata;
    logic        mem_re, misaligned;
    logic [3:0]  mem_wstrb;
    logic [31:0] mem_wdata, load_data;
    logic [31:0] rng = 32'h1a5e_2026;
    int unsigned checks = 0;

    lsu dut (
        .mem_read(mem_read), .mem_write(mem_write), .size(size),
        .is_unsigned(is_unsigned), .addr_offset(offset), .store_data(store_data),
        .mem_rdata(mem_rdata), .mem_re(mem_re), .mem_wstrb(mem_wstrb),
        .mem_wdata(mem_wdata), .load_data(load_data), .misaligned(misaligned)
    );

    function automatic logic [31:0] random_word();
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        return rng;
    endfunction

    function automatic int width(input mem_size_t s);
        case (s)
            MEM_BYTE: return 1;
            MEM_HALF: return 2;
            MEM_WORD: return 4;
            default:  return 0;
        endcase
    endfunction

    task automatic check(
        input logic rd, wr, input mem_size_t s, input logic uns,
        input logic [1:0] off, input logic [31:0] sdata, rdata
    );
        int n = width(s);
        logic e_mis;
        logic [3:0] e_strb;
        logic [31:0] e_load, old_word, new_word;
        mem_read = rd; mem_write = wr; size = s; is_unsigned = uns;
        offset = off; store_data = sdata; mem_rdata = rdata;
        #1;
        e_mis = (rd || wr) && (n == 0 || int'(off) % n != 0);

        // Load: gather n bytes starting at off, then extend.
        e_load = '0;
        if (rd && !e_mis)
            for (int i = 0; i < n; i++) e_load[i*8 +: 8] = rdata[(int'(off) + i)*8 +: 8];
        if (rd && !e_mis && !uns && n < 4 && e_load[n*8 - 1]) begin
            for (int i = n*8; i < 32; i++) e_load[i] = 1'b1;
        end

        // Store: the bytes of memory new_word the write must be sdata's low bytes.
        e_strb = '0;
        if (wr && !e_mis) for (int i = 0; i < n; i++) e_strb[int'(off) + i] = 1'b1;
        old_word = rdata;
        new_word = old_word;
        for (int lane = 0; lane < 4; lane++) begin
            if (mem_wstrb[lane]) new_word[lane*8 +: 8] = mem_wdata[lane*8 +: 8];
        end

        assert (misaligned === e_mis && mem_re === (rd && !e_mis) && mem_wstrb === e_strb)
            else $fatal(1, "rd=%b wr=%b size=%0d off=%0d: expected mis=%b re=%b strb=%b, got %b %b %b",
                        rd, wr, n, off, e_mis, rd && !e_mis, e_strb, misaligned, mem_re, mem_wstrb);
        if (rd && !e_mis) begin
            assert (load_data === e_load)
                else $fatal(1, "load size=%0d uns=%b off=%0d word=%h: expected %h, got %h",
                            n, uns, off, rdata, e_load, load_data);
        end
        if (wr && !e_mis) begin
            for (int i = 0; i < n; i++) begin
                assert (new_word[(int'(off) + i)*8 +: 8] === sdata[i*8 +: 8])
                    else $fatal(1, "store size=%0d off=%0d data=%h: byte %0d wrong (wdata=%h strb=%b)",
                                n, off, sdata, i, mem_wdata, mem_wstrb);
            end
        end
        checks++;
    endtask

    initial begin
        mem_size_t sizes [3] = '{MEM_BYTE, MEM_HALF, MEM_WORD};
        logic [31:0] words [4] = '{32'h8070_ff01, 32'h7fff_8000, 32'hffff_ffff, 32'h0000_0000};
        // Exhaustive over size x offset x signedness x read/write/none.
        foreach (sizes[s]) for (int off = 0; off < 4; off++) begin
            foreach (words[w]) begin
                check(1, 0, sizes[s], 0, 2'(off), 32'h0, words[w]);
                check(1, 0, sizes[s], 1, 2'(off), 32'h0, words[w]);
                check(0, 1, sizes[s], 0, 2'(off), words[w] ^ 32'h1234_5678, 32'hcccc_cccc);
            end
            check(0, 0, sizes[s], 0, 2'(off), 32'hffff_ffff, 32'hffff_ffff);
            check(1, 1, sizes[s], 0, 2'(off), 32'h7654_3210, 32'h89ab_cdef);
        end
        for (int off = 0; off < 4; off++)
            for (int enables = 0; enables < 4; enables++)
                check(1'(enables), 1'(enables >> 1), mem_size_t'(2'b11), 0,
                      2'(off), 32'h1234_5678, 32'hfedc_ba98);
        for (int unsigned trial = 0; trial < 20000; trial++) begin
            logic [6:0] c = 7'(random_word());
            check(c[0], !c[0] && c[1], sizes[c[3:2] % 3], c[4], c[6:5],
                  random_word(), random_word());
        end
        $display("PASS: lsu loads, stores, byte enables, extension and alignment contract (%0d checks; seed 1a5e2026)", checks);
        $finish;
    end
endmodule
