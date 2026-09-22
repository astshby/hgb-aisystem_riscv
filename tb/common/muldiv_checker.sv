// Module: muldiv_checker
// Description: Shared deterministic arithmetic, latency, backpressure, cancellation, and reset checks.
module muldiv_checker #(
    parameter int MODE = 0, // 0：统一 MDU；1：仅乘法；2：仅除法。
    parameter string TEST_NAME = "tb_muldiv_unit",
    parameter int MUL_IMPL = core_config_pkg::MUL_IMPL,
    parameter int DIV_IMPL = core_config_pkg::DIV_IMPL,
    parameter bit FINISH_ON_DONE = 1'b1
) (
    output logic finished = 1'b0
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic cancel = 1'b0;
    logic req_valid = 1'b0;
    logic req_ready;
    logic busy;
    muldiv_req_t request;
    logic rsp_valid;
    logic rsp_ready = 1'b0;
    xlen_t rsp_data;
    int checks = 0;
    logic [31:0] random_q = 32'h6760_7020;
    xlen_t corners [8];

    always #5 clk = ~clk;
    // 语义单元共用 MDU 的唯一握手壳；MODE 只筛选指令，不复制协议状态机。
    muldiv_unit #(.MUL_IMPL(MUL_IMPL), .DIV_IMPL(DIV_IMPL)) dut (
        .clk, .rst, .cancel, .req_valid, .req_ready, .request,
        .rsp_valid, .rsp_ready, .rsp_data, .busy
    );

    // TB 使用宽有符号乘法和原生除法作独立参考，不复用被测部分积或迭代算法。
    function automatic xlen_t reference_result(input muldiv_req_t req);
        logic signed [XLEN:0] a_wide;
        logic signed [XLEN:0] b_wide;
        logic signed [2*XLEN+1:0] product;
        xlen_t a;
        xlen_t b;
        xlen_t result;
        logic signed_div;
        a = req.operand_a;
        b = req.operand_b;
        signed_div = (req.operation == MD_DIV) || (req.operation == MD_REM);
        if (req.op_width == OP_WIDTH_WORD) begin
            a = xlen_t'(a[31:0]);
            b = xlen_t'(b[31:0]);
            if (signed_div) begin
                a = xlen_t'($signed(a[31:0]));
                b = xlen_t'($signed(b[31:0]));
            end
        end
        a_wide = {1'b0, a};
        b_wide = {1'b0, b};
        if ((req.operation == MD_MULH) || (req.operation == MD_MULHSU))
            a_wide = {a[XLEN-1], a};
        if (req.operation == MD_MULH)
            b_wide = {b[XLEN-1], b};
        product = a_wide * b_wide;
        unique case (req.operation)
            MD_MUL: result = product[XLEN-1:0];
            MD_MULH, MD_MULHSU, MD_MULHU: result = product[2*XLEN-1:XLEN];
            MD_DIV, MD_DIVU: begin
                if (b == '0)
                    result = '1;
                else if (signed_div && (a == (xlen_t'(1) << (XLEN-1))) && (b == '1))
                    result = a;
                else
                    result = signed_div ? xlen_t'($signed(a) / $signed(b)) : (a / b);
            end
            default: begin
                if (b == '0)
                    result = a;
                else if (signed_div && (a == (xlen_t'(1) << (XLEN-1))) && (b == '1))
                    result = '0;
                else
                    result = signed_div ? xlen_t'($signed(a) % $signed(b)) : (a % b);
            end
        endcase
        if (req.op_width == OP_WIDTH_WORD)
            result = xlen_t'($signed(result[31:0]));
        return result;
    endfunction

    function automatic logic [31:0] next_random();
        random_q = random_q ^ (random_q << 13);
        random_q = random_q ^ (random_q >> 17);
        random_q = random_q ^ (random_q << 5);
        return random_q;
    endfunction

    // 分两句生成，避免拼接表达式中多个有副作用调用的求值顺序差异。
    function automatic xlen_t random_operand();
        logic [31:0] high_word;
        logic [31:0] low_word;
        high_word = next_random();
        low_word = next_random();
        return xlen_t'({high_word, low_word});
    endfunction

    function automatic logic supported(input int operation, input op_width_e width);
        return !((MODE == 1) && (operation >= 4)) &&
               !((MODE == 2) && (operation < 4)) &&
               !((width == OP_WIDTH_WORD) && ((operation > 0) && (operation < 4)));
    endfunction

    task automatic launch(input muldiv_req_t req);
        @(negedge clk);
        assert (req_ready && !rsp_valid) else $fatal(1, "MDU not idle before request");
        request = req;
        req_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        // 请求变化不应影响已锁存的符号、操作数、W 选择和响应路由。
        request = '0;
        request.operation = (req.operation == MD_MUL) ? MD_DIV : MD_MUL;
        request.operand_a = '1;
    endtask

    task automatic check_operation(input muldiv_req_t req);
        xlen_t expected;
        int wait_cycles;
        int expected_wait;
        logic special;
        xlen_t a;
        xlen_t b;
        expected = reference_result(req);
        a = req.operand_a;
        b = req.operand_b;
        if (req.op_width == OP_WIDTH_WORD) begin
            a = xlen_t'($signed(a[31:0]));
            b = xlen_t'($signed(b[31:0]));
        end
        special = (b == '0) ||
            (((req.operation == MD_DIV) || (req.operation == MD_REM)) &&
             (b == '1) && (a == ((req.op_width == OP_WIDTH_WORD)
                ? xlen_t'($signed(32'h8000_0000)) : (xlen_t'(1) << (XLEN-1)))));
        if (int'(req.operation) < 4) begin
            if (MUL_IMPL == MUL_DSP)
                expected_wait = 0;
            else if (MUL_IMPL == MUL_BOOTH_WALLACE)
                expected_wait = 2;
            else
                expected_wait = XLEN;
        end
        else if (special)
            expected_wait = 0;
        else if (DIV_IMPL == DIV_SRT4)
            expected_wait = ((req.op_width == OP_WIDTH_WORD) ? 32 : XLEN) / 2 + 1;
        else
            expected_wait = (req.op_width == OP_WIDTH_WORD) ? 32 : XLEN;
        launch(req);
        wait_cycles = 0;
        while (!rsp_valid) begin
            assert (!req_ready) else $fatal(1, "MDU accepted second request while busy");
            @(negedge clk);
            wait_cycles++;
            if (wait_cycles > XLEN + 4)
                $fatal(1, "MDU response timeout");
        end
        assert (wait_cycles == expected_wait)
            else $fatal(1, "MDU latency got=%0d expected=%0d", wait_cycles, expected_wait);
        assert (rsp_data == expected)
            else $fatal(1, "MDU op=%0d width=%0d a=%h b=%h got=%h expected=%h",
                        req.operation, req.op_width, req.operand_a, req.operand_b, rsp_data, expected);
        repeat (3) begin
            @(negedge clk);
            assert (rsp_valid && !req_ready && rsp_data == expected)
                else $fatal(1, "MDU response changed under backpressure");
        end
        rsp_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        rsp_ready = 1'b0;
        assert (req_ready && !rsp_valid) else $fatal(1, "MDU response not consumed exactly once");
        checks++;
    endtask

    task automatic interrupt_operation(input logic reset_it, input logic wait_result,
                                       input muldiv_op_e operation);
        muldiv_req_t req;
        req = '0;
        req.operation = operation;
        req.operand_a = xlen_t'(32'hf123_4567);
        req.operand_b = xlen_t'(7);
        launch(req);
        if (wait_result) begin
            while (!rsp_valid) @(negedge clk);
        end else
            @(negedge clk);
        if (reset_it) rst = 1'b1;
        else cancel = 1'b1;
        @(posedge clk);
        @(negedge clk);
        assert (!rsp_valid && !req_ready) else $fatal(1, "cancel/reset handshake was not masked");
        rst = 1'b0;
        cancel = 1'b0;
        repeat (XLEN + 4) begin
            @(negedge clk);
            assert (!rsp_valid && req_ready) else $fatal(1, "late response after cancellation/reset");
        end
        check_operation(req);
    endtask

    initial begin
        muldiv_req_t req;
        request = '0;
        corners[0] = '0;
        corners[1] = xlen_t'(1);
        corners[2] = '1;
        corners[3] = xlen_t'(1) << (XLEN-1);
        corners[4] = corners[3] - xlen_t'(1);
        corners[5] = xlen_t'(32'h8000_0000);
        corners[6] = xlen_t'(32'hffff_ffff);
        corners[7] = xlen_t'(64'hdead_beef_0123_4567);
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (int width = 0; width < ((XLEN == 64) ? 2 : 1); width++)
            for (int operation = 0; operation < 8; operation++)
                if (supported(operation, op_width_e'(width))) begin
                    req.operation = muldiv_op_e'(operation);
                    req.op_width = op_width_e'(width);
                    for (int a_idx = 0; a_idx < 8; a_idx++)
                        for (int b_idx = 0; b_idx < 8; b_idx++) begin
                            req.operand_a = corners[a_idx];
                            req.operand_b = corners[b_idx];
                            check_operation(req);
                        end
                    for (int sample = 0; sample < 64; sample++) begin
                        req.operand_a = random_operand();
                        req.operand_b = random_operand();
                        check_operation(req);
                    end
                    // 改变除数数量级，避免均匀随机数大多只产生商 0/1。
                    for (int sample = 0; sample < 64; sample++) begin
                        req.operand_a = random_operand();
                        req.operand_b = (random_operand() >> (sample % XLEN)) | xlen_t'(1);
                        check_operation(req);
                    end
                end
        // 统一 MDU 额外交替后端，覆盖除法与乘法结果连续路由。
        if (MODE == 0)
            for (int sample = 0; sample < 32; sample++) begin
                req.operation = (sample % 2 == 0) ? MD_MULHSU : MD_REM;
                req.op_width = OP_WIDTH_XLEN;
                req.operand_a = random_operand();
                req.operand_b = random_operand();
                check_operation(req);
            end
        for (int backend = 0; backend < 2; backend++)
            if (supported(backend == 0 ? 1 : 4, OP_WIDTH_XLEN)) begin
                interrupt_operation(1'b0, 1'b0, backend == 0 ? MD_MULH : MD_DIV);
                interrupt_operation(1'b0, 1'b1, backend == 0 ? MD_MULH : MD_DIV);
                interrupt_operation(1'b1, 1'b0, backend == 0 ? MD_MULH : MD_DIV);
                interrupt_operation(1'b1, 1'b1, backend == 0 ? MD_MULH : MD_DIV);
            end
        $display("PASS %s RV%0d checks=%0d", TEST_NAME, XLEN, checks);
        finished = 1'b1;
        if (FINISH_ON_DONE) $finish;
    end

    initial begin
        #10000000;
        $fatal(1, "arithmetic checker timeout");
    end
endmodule
