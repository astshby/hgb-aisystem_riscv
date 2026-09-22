// Module: tb_mdu_unsigned
// Description: Exhaustive 8-bit cross-check of all five unsigned arithmetic backends.
module tb_mdu_unsigned;
    timeunit 1ns;
    timeprecision 1ps;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic cancel = 1'b0;
    logic start = 1'b0;
    logic div_start;
    logic [7:0] a, b;
    wire [4:0] done;
    wire [15:0] product [3];
    wire [7:0] quotient [2], remainder [2];
    logic [4:0] digit_seen = '0;
    logic [1:0] correction_seen = '0;
    int pairs = 0;

    always #5 clk = ~clk;
    assign div_start = start && (b != '0);
    mul_dsp #(.WIDTH(8)) u_dsp (.clk, .rst, .cancel, .start,
        .operand_a(a), .operand_b(b), .done(done[0]), .product(product[0]));
    mul_booth_wallace #(.WIDTH(8)) u_booth (.clk, .rst, .cancel, .start,
        .operand_a(a), .operand_b(b), .done(done[1]), .product(product[1]));
    mul_shift #(.WIDTH(8)) u_mul_shift (.clk, .rst, .cancel, .start,
        .operand_a(a), .operand_b(b), .done(done[2]), .product(product[2]));
    div_shift #(.WIDTH(8)) u_div_shift (.clk, .rst, .cancel, .start(div_start),
        .dividend(a), .divisor(b), .word_mode(1'b0),
        .done(done[3]), .quotient(quotient[0]), .remainder(remainder[0]));
    div_srt4 #(.WIDTH(8)) u_srt (.clk, .rst, .cancel, .start(div_start),
        .dividend(a), .divisor(b), .word_mode(1'b0),
        .done(done[4]), .quotient(quotient[1]), .remainder(remainder[1]));

    always @(posedge clk) begin
        if (!rst && !cancel) begin
            if (u_srt.active_q)
                digit_seen[int'($signed(u_srt.digit)) + 2] = 1'b1;
            if (u_srt.active_q && (u_srt.count_q == 1))
                correction_seen[u_srt.residual_binary < 0] = 1'b1;
        end
    end

    initial begin
        logic [4:0] seen;
        a = '0;
        b = '0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (int av = 0; av < 256; av++) begin
            for (int bv = 0; bv < 256; bv++) begin
                @(negedge clk);
                a = 8'(av);
                b = 8'(bv);
                start = 1'b1;
                @(posedge clk);
                @(negedge clk);
                start = 1'b0;
                seen = (bv == 0) ? 5'b11000 : '0;
                // 改变输入证明后端只观察 start 拍，而非迭代中重新采样。
                a = '1;
                b = '1;
                for (int cycle = 0; cycle < 10; cycle++) begin
                    for (int i = 0; i < 5; i++) begin
                        if (done[i]) begin
                            assert (!seen[i]) else $fatal(1, "repeated backend done index=%0d", i);
                            seen[i] = 1'b1;
                            if (i < 3)
                                assert (product[i] == 16'(av * bv))
                                    else $fatal(1, "unsigned mul backend=%0d a=%0d b=%0d", i, av, bv);
                            else begin
                                assert (quotient[i-3] == 8'(av / bv) && remainder[i-3] == 8'(av % bv))
                                    else $fatal(1, "unsigned div backend=%0d a=%0d b=%0d q=%0d r=%0d",
                                                i, av, bv, quotient[i-3], remainder[i-3]);
                            end
                        end
                    end
                    @(negedge clk);
                end
                assert (&seen) else $fatal(1, "missing unsigned backend completion");
                pairs++;
            end
        end
        assert (&digit_seen && &correction_seen)
            else $fatal(1, "SRT digit/correction coverage missing: %b %b", digit_seen, correction_seen);
        $display("PASS tb_mdu_unsigned pairs=%0d multiplier_checks=196608 divider_checks=130560 SRT_digits=5 correction_paths=2", pairs);
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1, "unsigned exhaustive timeout");
    end
endmodule
