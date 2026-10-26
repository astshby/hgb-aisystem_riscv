// Module: tb_mm3_fixed
// Description: Bit-exact independent C fixture comparison of multi-cycle dyadic operations.
module tb_mm3_fixed;
    timeunit 1ns;
    timeprecision 1ps;
    import mm3_fixed_pkg::*;
    logic clk = 0, rst = 1, start = 0, divide = 0, busy, done;
    fixed_t a, b, result, expected;
    int fd, count, fields, operation;
    logic [63:0] av, bv, ev;
    logic [31:0] ae, be, ee, q16, q32, flags;
    logic [3:0] actual_flags;
    function automatic logic [31:0] quant_word(input fixed_t v,input logic bits32);
        logic signed [31:0] q;
        q=32'(integer_mag(v,bits32));return v.v<0 ? -q:q;
    endfunction
    string path;
    always #5 clk = ~clk;
    mm3_fixed_math dut (.*);
    initial begin
        a = '0; b = '0; count = 0;
        if (!$value$plusargs("FIXTURE=%s",path)) $fatal(1,"missing fixture");
        fd = $fopen(path,"r");
        if (!fd) $fatal(1,"cannot open fixture");
        repeat (3) @(negedge clk);
        rst = 0;
        while (!$feof(fd)) begin
            fields = $fscanf(fd,"%d %h %h %h %h %h %h %h %h %h\n",operation,av,ae,bv,be,ev,ee,q16,q32,flags);
            a = {av,ae}; b = {bv,be}; expected = {ev,ee};
            if (fields != 10) $fatal(1,"bad fixture record %0d fields=%0d",count,fields);
            divide = 1'(operation); start = 1;
            @(negedge clk); start = 0;
            while (!done) @(negedge clk);
            assert (result === expected) else
                $fatal(1,"case=%0d op=%0d a=%h/%0d b=%h/%0d got=%h/%0d expected=%h/%0d",
                       count,divide,a.v,a.e,b.v,b.e,result.v,result.e,expected.v,expected.e);
            actual_flags={result.v!=0&&integer_mag(result,1)==0,quant_saturated(result,1),result.v!=0&&integer_mag(result,0)==0,quant_saturated(result,0)};
            assert(quant_word(result,0)==q16 && quant_word(result,1)==q32 && actual_flags==4'(flags))
                else $fatal(1,"quantization/flag mismatch case=%0d",count);
            count++;
            @(negedge clk);
        end
        assert (count == 1600) else $fatal(1,"fixture count %0d",count);
        $display("PASS MM3_FIXED %0d exact C multiply/divide cases",count);
        $finish;
    end
    initial begin #10000000; $fatal(1,"timeout"); end
endmodule
