`timescale 1ns/1ps
module vga_text_tb;
    logic clk = 0, clk_pixel = 0, rst = 1, rst_pixel = 1;
    logic cpu_en = 0, cpu_re = 0, visible = 0;
    logic [11:0] cpu_addr = 0;
    logic [3:0] cpu_wstrb = 0;
    logic [31:0] cpu_wdata = 0, fall_data, rise_data;
    logic [9:0] x = 0, y = 0;
    logic fall_pixel, rise_pixel;
    logic [31:0] model [600];
    int checks = 0;
    vga_text #(.CPU_READ_POSEDGE(0)) dut_fall (
        .clk(clk), .rst(rst), .cpu_en(cpu_en), .cpu_re(cpu_re), .cpu_addr(cpu_addr),
        .cpu_wstrb(cpu_wstrb), .cpu_wdata(cpu_wdata), .cpu_rdata(fall_data),
        .clk_pixel(clk_pixel), .rst_pixel(rst_pixel), .x(x), .y(y), .visible(visible), .pixel(fall_pixel));
    vga_text #(.CPU_READ_POSEDGE(1)) dut_rise (
        .clk(clk), .rst(rst), .cpu_en(cpu_en), .cpu_re(cpu_re), .cpu_addr(cpu_addr),
        .cpu_wstrb(cpu_wstrb), .cpu_wdata(cpu_wdata), .cpu_rdata(rise_data),
        .clk_pixel(clk_pixel), .rst_pixel(rst_pixel), .x(x), .y(y), .visible(visible), .pixel(rise_pixel));
    always #7 clk <= ~clk;
    always #20 clk_pixel <= ~clk_pixel;
    task automatic access(input int unsigned offset, input bit rd, input logic [3:0] mask,
                          input logic [31:0] value, input bit enabled = 1);
        logic [31:0] expected;
        expected = offset < 2400 ? model[offset/4] : 32'b0;
        @(posedge clk); #1;
        cpu_en = enabled; cpu_re = rd; cpu_addr = 12'(offset); cpu_wstrb = mask; cpu_wdata = value;
        @(posedge clk); #1;
        if (rd && enabled) begin
            assert (fall_data === expected && rise_data === expected)
                else $fatal(1, "text read offset %0d expected %h fall %h rise %h", offset, expected, fall_data, rise_data);
            checks++;
        end
        if (enabled && offset < 2400)
            for (int b = 0; b < 4; b++) if (mask[b]) model[offset/4][b*8 +: 8] = value[b*8 +: 8];
        cpu_en = 0; cpu_re = 0; cpu_wstrb = 0;
    endtask
    // Independent source-row constants, LSB at left BEFORE font conversion.
    function automatic logic source_pixel(input byte unsigned code, input int row, input logic [2:0] col);
        logic [7:0] rows [8];
        case (code)
            "A": rows = '{8'h0c,8'h1e,8'h33,8'h33,8'h3f,8'h33,8'h33,8'h00};
            "F": rows = '{8'h7f,8'h46,8'h16,8'h1e,8'h16,8'h06,8'h0f,8'h00};
            "!": rows = '{8'h18,8'h3c,8'h3c,8'h18,8'h18,8'h00,8'h18,8'h00};
            "?": rows = '{8'h1e,8'h33,8'h30,8'h18,8'h0c,8'h00,8'h0c,8'h00};
            default: rows = '{default:8'h00};
        endcase
        return rows[row/2][col];
    endfunction
    function automatic logic [7:0] cell_code(input int cell_n);
        byte unsigned codes [5] = '{"A", "F", "!", "?", " "};
        return codes[(cell_n*7 + cell_n/80) % 5];
    endfunction
    task automatic sample(input int px, py, input bit active, input logic expected);
        @(negedge clk_pixel); x = 10'(px); y = 10'(py); visible = active;
        repeat (3) @(posedge clk_pixel); #1;
        assert (fall_pixel === expected && rise_pixel === expected)
            else $fatal(1, "text pixel %0d,%0d expected %b fall %b rise %b", px, py, expected, fall_pixel, rise_pixel);
        checks++;
    endtask
    initial begin
        for (int i = 0; i < 600; i++) model[i] = 32'h2020_2020;
        repeat (4) @(negedge clk); rst = 0;
        @(negedge clk_pixel); rst_pixel = 0;
        access(0, 1, 0, 0); access(2396, 1, 0, 0);
        for (int mask = 0; mask < 16; mask++) begin
            access(0, 1, 4'(mask), 32'h3f21_4641); // also proves read-first
            access(0, 1, 0, 0);
        end
        access(0, 0, 15, 32'h3f21_4641, 0); access(0, 1, 0, 0);
        access(2400, 0, 15, '1); access(4092, 0, 15, '1);
        access(2400, 1, 0, 0); access(4092, 1, 0, 0); access(0, 1, 0, 0);
        access(2396, 0, 8, 32'h4100_0000);
        for (int row = 0; row < 16; row++)
            for (int col = 0; col < 32; col++)
                sample(col, row, 1, source_pixel(model[col/32][(col/8)*8 +: 8], row, 3'(col%8)));
        for (int row = 0; row < 16; row++)
            for (int col = 0; col < 8; col++)
                sample(632+col, 464+row, 1, source_pixel("A", row, 3'(col)));
        sample(0, 0, 0, 0); sample(799, 524, 0, 0);
        // Every one of the 2400 cells: a different glyph pattern per cell
        // catches a wrong row stride, word index or byte lane anywhere on
        // the screen, not only in the first word and the last cell.
        for (int word = 0; word < 600; word++) begin
            logic [31:0] value;
            for (int lane = 0; lane < 4; lane++) value[lane*8 +: 8] = cell_code(word*4 + lane);
            access(word*4, 0, 15, value);
            access(word*4, 1, 0, 0);
        end
        for (int cell_n = 0; cell_n < 2400; cell_n++) begin
            int row;
            row = cell_n % 16;
            for (int col = 0; col < 8; col++)
                sample((cell_n%80)*8 + col, (cell_n/80)*16 + row, 1,
                       source_pixel(cell_code(cell_n), row, 3'(col)));
        end
        // CPU reset resets the read register, never the character RAM.
        @(negedge clk); rst = 1;
        repeat (2) @(negedge clk); rst = 0;
        access(0, 1, 0, 0); access(2396, 1, 0, 0);
        $display("PASS: text both CPU edges, every byte mask, read-first/readback, reserved bounds, asynchronous pixel clock, glyph orientation, all 2400 cells, reset retention (%0d checks)", checks);
        $finish;
    end
    initial begin #10000000; $fatal(1, "TIMEOUT: VGA text"); end
endmodule
