// Module: tb_div_srt4_components
// Description: Checks normalization, PD-QDS bounds, carry-save identity, and OTF conversion.
module tb_div_srt4_components;
    timeunit 1ns;
    timeprecision 1ps;

    logic [19:0] partial_sum, partial_carry;
    logic [3:0] divisor_prefix;
    logic signed [2:0] digit;
    logic signed [2:0] otf_digit;
    logic [9:0] quotient, quotient_minus_one, next_quotient, next_minus_one;
    logic [7:0] normalize_dividend, normalize_divisor, normalized_divisor;
    logic [15:0] normalized_dividend;
    logic [2:0] normalize_shift;
    logic [19:0] csa_a, csa_b, csa_addend, csa_sum, csa_carry;
    int qds_checks = 0;
    int otf_checks = 0;

    div_srt4_qds #(.WIDTH(20)) u_qds (.*);
    div_srt4_otf #(.WIDTH(10)) u_otf (
        .digit(otf_digit),
        .quotient,
        .quotient_minus_one,
        .next_quotient,
        .next_minus_one
    );
    div_srt4_normalize #(.WIDTH(8)) u_normalize (
        .dividend(normalize_dividend),
        .divisor(normalize_divisor),
        .shift(normalize_shift),
        .normalized_dividend,
        .normalized_divisor
    );
    div_srt4_csa #(.WIDTH(20)) u_csa (
        .row_a(csa_a),
        .row_b(csa_b),
        .addend(csa_addend),
        .sum(csa_sum),
        .carry(csa_carry)
    );

    initial begin
        int residual;
        int limit;
        int partial_value;
        int target_value;
        normalize_dividend = '0;
        normalize_divisor = '0;
        partial_sum = '0;
        partial_carry = '0;
        divisor_prefix = 4'h8;
        quotient = '0;
        quotient_minus_one = '1;
        otf_digit = '0;
        csa_a = '0;
        csa_b = '0;
        csa_addend = '0;

        // 穷举 8 位归一化除数及可达余数，检查商位使残差保持在 ±2D/3。
        for (int d = 128; d <= 255; d++) begin
            limit = (8*d) / 3;
            for (int p = -limit; p <= limit; p++) begin
                partial_sum = 20'(p * 256);
                partial_carry = '0;
                divisor_prefix = 4'(d >> 4);
                #1;
                residual = p - int'($signed(digit)) * d;
                assert ((int'($signed(digit)) >= -2) &&
                        (int'($signed(digit)) <= 2) &&
                        (3*residual <= 2*d) && (3*residual >= -2*d))
                    else $fatal(1, "PD-QDS failed P=%0d D=%0d digit=%0d", p, d, digit);
                qds_checks++;
            end
        end

        // 用不同的 sum/carry 分解表示同一余数，覆盖 QDS 丢弃低位进位的不确定性。
        for (int sample = 0; sample < 4096; sample++) begin
            int d;
            d = 128 + (sample % 128);
            limit = (8*d) / 3;
            partial_value = ((sample * 37) % (2*limit + 1)) - limit;
            target_value = partial_value * 256;
            partial_carry = 20'((sample * 20'h2d35b) & 20'hfffff);
            partial_sum = 20'(target_value - int'(partial_carry));
            divisor_prefix = 4'(d >> 4);
            #1;
            residual = partial_value - int'($signed(digit)) * d;
            assert ((3*residual <= 2*d) && (3*residual >= -2*d))
                else $fatal(1, "carry-save QDS failed P=%0d D=%0d digit=%0d",
                            partial_value, d, digit);
            qds_checks++;
        end

        // CSA 的两行输出在固定位宽下必须等于三个输入之和。
        for (int sample = 0; sample < 4096; sample++) begin
            csa_a = 20'(sample * 20'h13579);
            csa_b = 20'(sample * 20'h2468b);
            csa_addend = 20'(sample * 20'h31f27);
            #1;
            assert (20'(csa_sum + csa_carry) ==
                    20'(csa_a + csa_b + csa_addend))
                else $fatal(1, "CSA identity failed sample=%0d", sample);
        end

        normalize_dividend = 8'hf3;
        normalize_divisor = 8'h01;
        #1;
        assert ((normalize_shift == 3'd7) && (normalized_divisor == 8'h80) &&
                (normalized_dividend == 16'h7980))
            else $fatal(1, "normalization boundary");

        normalize_dividend = 8'h03;
        normalize_divisor = 8'h50;
        #1;
        assert ((normalize_shift == 3'd1) && (normalized_divisor == 8'ha0) &&
                (normalized_dividend == 16'h0006))
            else $fatal(1, "normalization common case");

        for (int q = 0; q < 1024; q++) begin
            for (int d = -2; d <= 2; d++) begin
                quotient = 10'(q);
                quotient_minus_one = 10'(q-1);
                otf_digit = 3'(d);
                #1;
                assert ((next_quotient == 10'(4*q+d)) &&
                        (next_minus_one == 10'(4*q+d-1)))
                    else $fatal(1, "OTF failed q=%0d digit=%0d", q, d);
                otf_checks++;
            end
        end
        $display("PASS tb_div_srt4_components QDS=%0d CSA=4096 OTF=%0d",
                 qds_checks, otf_checks);
        $finish;
    end
endmodule
