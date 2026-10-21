// Module: tb_branch_result_register
// Description: Checks exact capture latency, operand readiness, holding, advance, cancel, and reset.
module tb_branch_result_register;
    timeunit 1ns;
    timeprecision 1ps;
    import core_types_pkg::*;
    logic clk = 0, rst = 1, cancel = 0, advance = 0;
    logic selected = 0, operands_ready = 0;
    logic computed_taken = 0, taken, wait_for_result;
    xlen_t computed_target = '0, target;
    int checks = 0;
    always #5 clk = ~clk;
    branch_result_register dut (.*);

    task automatic check(input logic waiting, input logic expected_taken,
                         input xlen_t expected_target);
        #1;
        assert (wait_for_result == waiting) else $fatal(1, "branch wait check %0d", checks);
        if (selected && !waiting)
            assert (taken == expected_taken && target == expected_target)
                else $fatal(1, "branch payload check %0d", checks);
        checks++;
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 0;
        computed_target = xlen_t'(32'h40);
        check(0, 0, xlen_t'(32'h40));
        selected = 1;
        repeat (3) begin
            computed_target += xlen_t'(4);
            check(1, 0, '0);
            @(negedge clk);
        end
        operands_ready = 1;
        computed_taken = 1;
        computed_target = xlen_t'(32'h80);
        check(1, 0, '0); // 沿前仍等待，不能组合绕过结果槽。
        @(negedge clk);
        check(0, 1, xlen_t'(32'h80));
        repeat (4) begin
            computed_taken = 0;
            computed_target += xlen_t'(16);
            operands_ready = !operands_ready;
            @(negedge clk);
            check(0, 1, xlen_t'(32'h80));
        end

        advance = 1;
        @(negedge clk);
        advance = 0;
        selected = 0;
        // 未选中时不要求载荷有效，但原始输入的变化不能穿透保存槽。
        repeat (3) begin
            computed_taken = !computed_taken;
            computed_target += xlen_t'(32);
            check(0, 0, '0);
            assert (taken && target == xlen_t'(32'h80))
                else $fatal(1, "unselected branch output bypassed its register");
        end
        selected = 1;
        operands_ready = 1;
        computed_taken = 0;
        computed_target = xlen_t'(32'h124);
        check(1, 0, '0);
        @(negedge clk);
        check(0, 0, xlen_t'(32'h124));

        // 满槽取消立即禁止交付；下一条必须重新捕获，不能重放旧目标。
        cancel = 1;
        check(1, 0, '0);
        @(negedge clk);
        cancel = 0;
        computed_taken = 1;
        computed_target = xlen_t'(32'h208);
        check(1, 0, '0);
        @(negedge clk);
        check(0, 1, xlen_t'(32'h208));
        rst = 1;
        check(1, 0, '0);
        @(negedge clk);
        rst = 0;
        cancel = 1;
        @(negedge clk);
        cancel = 0;
        computed_target = xlen_t'(32'h300);
        check(1, 0, '0);
        @(negedge clk);
        check(0, 1, xlen_t'(32'h300));
        $display("PASS tb_branch_result_register RV%0d checks=%0d", core_config_pkg::XLEN, checks);
        $finish;
    end
endmodule
