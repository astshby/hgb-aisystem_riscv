// Module: div_unit
// Description: Shared RISC-V boundary, magnitude and sign handling around selectable unsigned dividers.
// M扩展除法专用模块；接收 start 与cancel，返回 done 与 计算结果。
// 写入a，b后先判断是否是特殊情况，然后取abs后计算，最后根据符号和操作类型返回结果。
module div_unit #(
    parameter int IMPL = core_config_pkg::DIV_IMPL
) (
    input logic clk, rst, cancel, start,
    input core_types_pkg::muldiv_req_t request,
    output logic done,
    output core_types_pkg::xlen_t result,
    output logic special_case,
    output core_types_pkg::xlen_t special_result
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    // 除法同时生成商与余数
    xlen_t operand_a, operand_b, abs_a, abs_b;
    logic signed_op, a_negative, b_negative;
    xlen_t quotient, remainder;
    logic want_remainder_q, quotient_negative_q, remainder_negative_q;
    op_width_e op_width_q;

    // W 形式的32/64都有4种。
    always_comb begin
        signed_op = (request.operation == MD_DIV) || (request.operation == MD_REM);
        operand_a = request.operand_a;
        operand_b = request.operand_b;
        if (request.op_width == OP_WIDTH_WORD) begin
            operand_a = xlen_t'(request.operand_a[31:0]);
            operand_b = xlen_t'(request.operand_b[31:0]);
            if (signed_op) begin
                operand_a = {{(XLEN-32){request.operand_a[31]}}, request.operand_a[31:0]};
                operand_b = {{(XLEN-32){request.operand_b[31]}}, request.operand_b[31:0]};
            end
        end
    end

    // 先处理除零和最小负数/-1；切记没有异常，是特殊值。
    always_comb begin
        // 给明除法特殊值
        special_case = (operand_b == '0) ||
            (signed_op && (operand_b == '1) &&
             (operand_a == ((request.op_width == OP_WIDTH_WORD)
                 ? xlen_t'($signed(32'h8000_0000)) : (xlen_t'(1) << (XLEN-1)))));

        special_result = '0;
        // /0：除法给全1，余数给a
        // 溢出(有符号有):除法给a，余数给0
        if (operand_b == '0)
            special_result = ((request.operation == MD_REM) || (request.operation == MD_REMU))
                           ? operand_a : '1;
        else if (request.operation == MD_DIV)
            special_result = operand_a;
        // special的W也要符合：保留低32位+符号扩展
        if (request.op_width == OP_WIDTH_WORD)
            special_result = {{(XLEN-32){special_result[31]}}, special_result[31:0]};
    end

    // 再求 abs,符号标与真正的计算start（abs有特殊值保持0）
    always_comb begin
        a_negative = signed_op && operand_a[XLEN-1];
        b_negative = signed_op && operand_b[XLEN-1];
        abs_a = special_case ? '0 : (a_negative ? ('0 - operand_a) : operand_a);
        abs_b = special_case ? '0 : (b_negative ? ('0 - operand_b) : operand_b);
    end

    // 选择除法器
    generate
        if (IMPL == DIV_SHIFT) begin : g_shift
            div_shift u_backend (.clk, .rst, .cancel, .start(start && !special_case),
                .dividend(abs_a), .divisor(abs_b),
                .word_mode(request.op_width == OP_WIDTH_WORD),
                .done, .quotient, .remainder);
        end else if (IMPL == DIV_SRT4) begin : g_srt
            div_srt4 u_backend (.clk, .rst, .cancel, .start(start && !special_case),
                .dividend(abs_a), .divisor(abs_b),
                .word_mode(request.op_width == OP_WIDTH_WORD),
                .done, .quotient, .remainder);
        end else begin : g_invalid
            initial $fatal(1, "invalid divider implementation");
        end
    endgenerate

    // 结果输出：want_remainder_q+响应negetive决定，最后处理 W 扩展。
    always_comb begin
        if (want_remainder_q)
            result = remainder_negative_q ? ('0 - remainder) : remainder;
        else
            result = quotient_negative_q ? ('0 - quotient) : quotient;
        if (op_width_q == OP_WIDTH_WORD)
            result = {{(XLEN-32){result[31]}}, result[31:0]};
    end

    // 特殊值直接接收；普通值才启动后端除法器。
    always_ff @(posedge clk) begin
        if (!rst && !cancel && start && !special_case) begin
            want_remainder_q <= (request.operation == MD_REM) || (request.operation == MD_REMU);
            quotient_negative_q <= a_negative ^ b_negative;
            remainder_negative_q <= a_negative;
            op_width_q <= request.op_width;
        end
    end
endmodule
